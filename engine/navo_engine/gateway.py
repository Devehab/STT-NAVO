"""Navo engine gateway: the always-on front door on 127.0.0.1:7861.

The gateway is small (no ML libraries). The models live in a separate worker process
(navo_engine.server) that the gateway starts when a request needs a model and stops when
every model has been idle for the configured time, so the memory goes back to macOS.

* A model that is not used for ``idle_minutes`` is unloaded inside the worker.
* When nothing is loaded any more, the worker process exits: only the gateway remains.
* Any request that needs a model starts the worker again and loads that model. Nothing
  changes for API clients except that the first request after a sleep takes longer.
* ``idle_minutes = 0`` keeps everything loaded, as before.
* At most two speech engines are on at once. Turning on a third answers 409, even while the
  worker sleeps, until one of the others is turned off.
* The language models (Gemma, Llama) live in the worker too. A chat request wakes the worker,
  which frees the speech models, loads the language model and answers; streamed answers are
  passed on piece by piece.
"""

from __future__ import annotations

import argparse
import asyncio
import copy
import logging
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import asynccontextmanager
from typing import Callable, Optional

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

from . import DEFAULT_PORT, __version__, package_version
from .engines import PROFILES, limit_message, too_many_enabled
from .llms import LLM_PROFILES, MEMORY_LIMIT_BYTES
from .models import cached_snapshot, dir_size
from .options import add_model_arguments, check_engine_limit, llm_overrides, model_overrides, watch_parent

log = logging.getLogger("navo.gateway")

DEFAULT_IDLE_MINUTES = 10.0
START_TIMEOUT_SECONDS = 180
STOP_GRACE_SECONDS = 10


class WorkerUnavailable(RuntimeError):
    pass


class Gateway:
    """Owns the settings that outlive the worker and starts or stops the worker."""

    def __init__(
        self,
        args: argparse.Namespace,
        idle_minutes: float,
        command: Optional[Callable[["Gateway", bool], list[str]]] = None,
        check_interval: float = 15.0,
        settle_seconds: float = 20.0,
    ):
        self.args = args
        self.enabled: list[str] = list(args.engines)
        self.default_engine = (args.default_engine or (self.enabled[0] if self.enabled else "cohere")).lower()
        self.models = model_overrides(args)
        self.llm_models = llm_overrides(args)
        self.last_llms: dict[str, dict] = {}  # last report from the worker
        self.idle_minutes = idle_minutes
        self.check_interval = check_interval
        self.settle_seconds = settle_seconds  # never stop a worker that was used this recently
        self._command = command or default_worker_command
        self.process: Optional[subprocess.Popen] = None
        self.socket_dir = tempfile.mkdtemp(prefix="navo-")
        self.socket_path = os.path.join(self.socket_dir, "worker.sock")
        self.client: Optional[httpx.AsyncClient] = None
        self.lock = asyncio.Lock()
        self.state = "sleeping"  # sleeping, starting, running, failed
        self.failure: Optional[str] = None
        self.in_flight = 0
        self.last_activity = time.monotonic()
        self.waking: set[str] = set()
        self.carried: dict[str, int] = {}  # transcriptions served by earlier workers
        self.last_engines: dict[str, dict] = {}  # last report from the worker, to keep errors visible
        self.started_at = time.time()
        self.sleeps = 0
        self.last_report: Optional[dict] = None

    # Worker process

    @property
    def running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    async def open(self) -> None:
        self.client = httpx.AsyncClient(
            transport=httpx.AsyncHTTPTransport(uds=self.socket_path),
            base_url="http://navo-worker",
            timeout=httpx.Timeout(None, connect=5.0),
        )

    async def close(self) -> None:
        await self.stop_worker("the engine is shutting down")
        if self.client is not None:
            await self.client.aclose()
        shutil.rmtree(self.socket_dir, ignore_errors=True)

    async def _ping(self, timeout: float = 5.0) -> Optional[dict]:
        try:
            response = await self.client.get("/health", timeout=timeout)
            report = response.json() if response.status_code == 200 else None
        except (httpx.HTTPError, ValueError):
            return None
        if report is not None:
            self.last_report = report
        return report

    async def ensure_worker(self, preload_all: bool = False) -> None:
        """Starts the worker if it is not running and waits until it answers."""
        async with self.lock:
            if self.running and await self._ping() is not None:
                return
            if not self.running:
                try:
                    os.unlink(self.socket_path)
                except OSError:
                    pass
                command = self._command(self, preload_all)
                log.info("Starting the model worker")
                self.state, self.failure = "starting", None
                self.process = subprocess.Popen(command, env=os.environ.copy())
            deadline = time.monotonic() + START_TIMEOUT_SECONDS
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    code = self.process.returncode
                    self.process = None
                    self.state = "failed"
                    self.failure = f"The model worker exited while starting (exit code {code}). See the engine log."
                    raise WorkerUnavailable(self.failure)
                if await self._ping() is not None:
                    self.state = "running"
                    self.waking.clear()
                    return
                await asyncio.sleep(0.2)
            self.state = "failed"
            self.failure = "The model worker did not start in time. See the engine log."
            raise WorkerUnavailable(self.failure)

    async def stop_worker(self, reason: str, only_if_idle: bool = False) -> bool:
        """Stops the worker. With only_if_idle, gives up if a request arrived meanwhile."""
        async with self.lock:
            if only_if_idle and (self.in_flight or time.monotonic() - self.last_activity < min(self.settle_seconds, self.idle_minutes * 60)):
                return False
            await self._stop(reason)
            return True

    async def _stop(self, reason: str) -> None:
        process = self.process
        if process is None:
            return
        report = await self._ping() if process.poll() is None else None
        if report:
            self._remember(report, carry=True)
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                await asyncio.wait_for(asyncio.to_thread(process.wait), STOP_GRACE_SECONDS)
            except asyncio.TimeoutError:
                process.kill()
                await asyncio.to_thread(process.wait)
        self.process = None
        self.state = "sleeping"
        self.waking.clear()
        self.last_report = None
        self.sleeps += 1
        log.info("Model worker stopped (%s); its memory is back with macOS", reason)

    def _remember(self, report: dict, carry: bool = False) -> None:
        for entry in report.get("llms") or []:
            self.last_llms[entry["id"]] = entry
        for entry in report.get("engines") or []:
            self.last_engines[entry["id"]] = entry
            if carry:
                self.carried[entry["id"]] = self.carried.get(entry["id"], 0) + int(entry.get("transcriptions") or 0)

    # Idle policy

    async def idle_loop(self) -> None:
        while True:
            await asyncio.sleep(self.check_interval)
            try:
                await self.check_idle()
            except Exception:  # never let the loop die
                log.exception("Idle check failed")

    async def check_idle(self) -> None:
        if self.idle_minutes <= 0 or not self.running or self.in_flight or self.lock.locked():
            return
        report = await self._ping()
        if report is None:
            return
        limit = self.idle_minutes * 60
        busy = False
        for entry in report.get("engines") or []:
            if entry.get("status") == "loading":
                busy = True
            elif entry.get("status") == "ready":
                if (entry.get("idle_seconds") or 0) >= limit:
                    log.info("%s idle for %g min, unloading it", entry.get("name"), self.idle_minutes)
                    await self.client.post(f"/v1/engines/{entry['id']}/unload")
                else:
                    busy = True
        # A language model leaves memory on its own (its keep alive time); until then the worker stays.
        if any(entry.get("status") in ("loading", "ready", "writing") for entry in report.get("llms") or []):
            busy = True
        llm = report.get("llm") or {}
        if llm.get("loaded_model"):
            if (llm.get("idle_seconds") or 0) >= limit:
                log.info("Cleanup model idle for %g min, unloading it", self.idle_minutes)
                await self.client.post("/v1/cleanup/unload")
            else:
                busy = True
        if not busy:
            await self.stop_worker(f"no model used for {self.idle_minutes:g} min", only_if_idle=True)

    # Reports while the worker sleeps

    def engine_report(self, engine_id: str) -> dict:
        profile = PROFILES[engine_id]
        last = self.last_engines.get(engine_id, {})
        if engine_id not in self.enabled:
            status, error = "off", None
        elif self.state == "starting" and engine_id in self.waking:
            status, error = "loading", None
        elif last.get("status") == "error":
            status, error = "error", last.get("error")
        else:
            status, error = "asleep", None
        return {
            "id": engine_id,
            "name": profile.name,
            "model": self.models[engine_id],
            "languages": list(profile.languages),
            "status": status,
            "downloaded": cached_snapshot(self.models[engine_id]) is not None,
            "backend": None,
            "device": None,
            "error": error,
            "load_seconds": None,
            "idle_seconds": None,
            "model_path": last.get("model_path"),
            "model_bytes": last.get("model_bytes"),
            "transcriptions": self.carried.get(engine_id, 0),
            "last_processing_ms": last.get("last_processing_ms"),
            "default": engine_id == self.default_engine,
        }

    def llm_report(self, llm_id: str) -> dict:
        profile = LLM_PROFILES[llm_id]
        last = self.last_llms.get(llm_id, {})
        model = self.llm_models[llm_id]
        failed = last.get("status") == "error"
        return {
            "id": llm_id,
            "name": profile.name,
            "maker": profile.maker,
            "license": profile.license,
            "model": model,
            "status": "error" if failed else "asleep",
            "downloaded": cached_snapshot(model) is not None,
            "error": last.get("error") if failed else None,
            "load_seconds": None,
            "idle_seconds": None,
            "model_path": last.get("model_path"),
            "model_bytes": last.get("model_bytes"),
            "context_tokens": self.args.llm_context,
            "memory_limit_bytes": MEMORY_LIMIT_BYTES,
            "peak_memory_bytes": last.get("peak_memory_bytes"),
            "requests": last.get("requests", 0),
            "last_tokens_per_second": last.get("last_tokens_per_second"),
        }

    def sleeping_health(self) -> dict:
        engines = [self.engine_report(engine_id) for engine_id in PROFILES]
        default = next(e for e in engines if e["id"] == self.default_engine)
        llm_path = cached_snapshot(self.args.llm_model)
        return {
            "service": "navo-engine",
            "role": "gateway",
            "version": __version__,
            "default_engine": self.default_engine,
            "engines": engines,
            "status": default["status"],
            "backend": None,
            "model": default["model"],
            "error": default["error"] or self.failure,
            "load_seconds": None,
            "uptime_seconds": round(time.time() - self.started_at, 1),
            "offline": os.environ.get("HF_HUB_OFFLINE") == "1",
            "device": None,
            "model_path": default["model_path"],
            "model_bytes": default["model_bytes"],
            "transcriptions": sum(e["transcriptions"] for e in engines),
            "last_processing_ms": default["last_processing_ms"],
            "llm": {
                "default_model": self.args.llm_model,
                "loaded_model": None,
                "available": llm_path is not None,
                "path": str(llm_path) if llm_path else None,
                "size_bytes": dir_size(llm_path) if llm_path else None,
                "idle_seconds": None,
                "error": None,
            },
            "llms": [self.llm_report(llm_id) for llm_id in LLM_PROFILES],
            "mlx_lm_version": package_version("mlx-lm"),
        }

    def add_carried(self, report: dict) -> dict:
        """Counts from earlier workers, so totals survive sleeps. For live worker reports only."""
        engines = report.get("engines") or []
        for entry in engines:
            entry["transcriptions"] = int(entry.get("transcriptions") or 0) + self.carried.get(entry["id"], 0)
        report["transcriptions"] = sum(int(e.get("transcriptions") or 0) for e in engines)
        return report

    def decorate(self, report: dict) -> dict:
        """Adds the gateway's view to a report: its process, the worker process and sleep settings."""
        worker_pid = report.get("pid") if report.get("role") == "worker" else None
        report.update(
            {
                "role": "gateway",
                "pid": os.getpid(),
                "worker_pid": worker_pid,
                "worker": self.state,
                "sleeping": worker_pid is None,
                "idle_minutes": self.idle_minutes,
                "host": self.args.host,
                "port": self.args.port,
            }
        )
        if self.failure and not self.running:
            report["worker_error"] = self.failure
        return report


def default_worker_command(gateway: Gateway, preload_all: bool) -> list[str]:
    args = gateway.args
    command = [
        sys.executable, "-m", "navo_engine.server",
        "--uds", gateway.socket_path,
        "--engines", ",".join(gateway.enabled) or "none",
        "--default-engine", gateway.default_engine,
        "--preload", ",".join(gateway.enabled) if preload_all else "none",
        "--asr-model", gateway.models["cohere"],
        "--audar-model", gateway.models["audar"],
        "--whisper-model", gateway.models["whisper"],
        "--qwen3-model", gateway.models["qwen3"],
        "--llm-model", args.llm_model,
        "--gemma-model", gateway.llm_models["gemma"],
        "--llama-model", gateway.llm_models["llama"],
        "--llm-context", str(args.llm_context),
        "--llm-keep-alive", str(args.llm_keep_alive),
        "--backend", args.backend,
        "--parent-pid", str(os.getpid()),
    ]
    if args.allow_download:
        command.append("--allow-download")
    if not preload_all or args.no_preload_llm:
        command.append("--no-preload-llm")
    return command


LOCAL_ENGINE_ACTIONS = {"enable", "disable", "default", "unload"}


def create_gateway_app(gateway: Gateway) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await gateway.open()
        task = asyncio.create_task(gateway.idle_loop())
        if gateway.idle_minutes <= 0:
            try:
                await gateway.ensure_worker(preload_all=True)
            except WorkerUnavailable as exc:
                log.error("%s", exc)
        try:
            yield
        finally:
            task.cancel()
            await gateway.close()

    app = FastAPI(title="Navo Engine", version=__version__, lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

    def worker_error(exc: Exception) -> JSONResponse:
        detail = str(exc) if isinstance(exc, WorkerUnavailable) else f"The model worker stopped answering: {exc}"
        return JSONResponse({"detail": detail}, status_code=503)

    async def forward(request: Request, path: str, body: Optional[bytes] = None) -> Response:
        if body is None:
            body = await request.body()
        headers = {k: v for k, v in request.headers.items() if k.lower() in ("content-type", "accept")}
        response = await gateway.client.request(
            request.method, "/" + path, params=request.query_params, content=body, headers=headers
        )
        return Response(
            content=response.content,
            status_code=response.status_code,
            media_type=response.headers.get("content-type"),
        )

    async def forward_stream(request: Request, path: str, body: bytes, done: Callable[[], None]) -> Response:
        """Like forward, but a streamed answer (server-sent events) is passed on as it arrives.

        ``done`` is called once, when the answer has been passed on in full or the client left.
        """
        headers = {k: v for k, v in request.headers.items() if k.lower() in ("content-type", "accept")}
        upstream = gateway.client.build_request(
            request.method, "/" + path, params=request.query_params, content=body, headers=headers
        )
        try:
            response = await gateway.client.send(upstream, stream=True)
        except BaseException:
            done()
            raise
        media_type = response.headers.get("content-type")
        if "text/event-stream" not in (media_type or ""):
            try:
                content = await response.aread()
            finally:
                await response.aclose()
                done()
            return Response(content=content, status_code=response.status_code, media_type=media_type)

        async def relay():
            try:
                async for piece in response.aiter_raw():
                    gateway.last_activity = time.monotonic()
                    yield piece
            finally:
                await response.aclose()  # the worker sees the client leave and stops writing
                done()

        return StreamingResponse(
            relay(),
            status_code=response.status_code,
            media_type=media_type,
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    async def report() -> dict:
        if not gateway.running and gateway.state == "running":
            code = gateway.process.returncode if gateway.process is not None else None
            gateway.process, gateway.state = None, "sleeping"
            gateway.failure = f"The model worker stopped unexpectedly (exit code {code}). It restarts on the next request."
            gateway.waking.clear()
            gateway.last_report = None
            log.warning("%s", gateway.failure)
        if gateway.running:
            live = await gateway._ping(timeout=1.0)
            if live is None and gateway.state == "running" and gateway.last_report is not None:
                live = copy.deepcopy(gateway.last_report)  # busy for a moment: report what it said last
            if live is not None:
                gateway._remember(live)
                return gateway.decorate(gateway.add_carried(copy.deepcopy(live)))
        return gateway.decorate(gateway.sleeping_health())

    @app.get("/health")
    async def health() -> dict:
        return await report()

    @app.get("/v1/engines")
    async def engines() -> dict:
        data = await report()
        return {"default_engine": data["default_engine"], "engines": data["engines"]}

    @app.get("/v1/llms")
    async def llms() -> dict:
        return {"llms": (await report())["llms"]}

    @app.get("/v1/sleep")
    async def sleep_settings() -> dict:
        return {"idle_minutes": gateway.idle_minutes, "worker": gateway.state, "sleeps": gateway.sleeps}

    @app.post("/v1/sleep")
    async def set_sleep(request: Request) -> Response:
        try:
            minutes = float((await request.json()).get("idle_minutes"))
        except (TypeError, ValueError, AttributeError):
            return JSONResponse({"detail": "Send JSON like {\"idle_minutes\": 10} (0 keeps models loaded)"}, status_code=400)
        gateway.idle_minutes = max(0.0, minutes)
        log.info("Idle time set to %g min", gateway.idle_minutes)
        return JSONResponse(await sleep_settings())

    @app.post("/v1/sleep/now")
    async def sleep_now() -> Response:
        if gateway.in_flight:
            return JSONResponse({"detail": "A request is running. Try again when it finishes."}, status_code=409)
        await gateway.stop_worker("asked to free memory now")
        return JSONResponse(await sleep_settings())

    @app.get("/{engine_id}/health")
    async def engine_health(engine_id: str) -> Response:
        if engine_id in LLM_PROFILES:
            data = await report()
            return JSONResponse(next(e for e in data["llms"] if e["id"] == engine_id))
        if engine_id not in PROFILES:
            known = ", ".join([*PROFILES, *LLM_PROFILES])
            return JSONResponse({"detail": f"Unknown engine '{engine_id}'. Use one of: {known}"}, status_code=404)
        data = await report()
        return JSONResponse(next(e for e in data["engines"] if e["id"] == engine_id))

    @app.post("/v1/llms/unload")
    async def unload_llms(request: Request) -> Response:
        if not gateway.running:  # nothing is loaded: do not wake the worker to free it
            return JSONResponse({"llms": gateway.sleeping_health()["llms"]})
        return await waking(request, "v1/llms/unload")

    @app.post("/v1/llms/{llm_id}/{action}")
    async def llm_action(llm_id: str, action: str, request: Request) -> Response:
        if llm_id not in LLM_PROFILES:
            return JSONResponse(
                {"detail": f"Unknown language model '{llm_id}'. Use one of: {', '.join(LLM_PROFILES)}"}, status_code=404
            )
        if action not in ("load", "unload"):
            return JSONResponse({"detail": f"Unknown action '{action}'"}, status_code=404)
        if action == "unload" and not gateway.running:
            return JSONResponse(gateway.llm_report(llm_id))
        if action == "load" and cached_snapshot(gateway.llm_models[llm_id]) is None:
            profile = LLM_PROFILES[llm_id]
            return JSONResponse(
                {"detail": f"{profile.name} is not downloaded yet. Download it in Navo > Settings > AI writing."},
                status_code=503,
            )
        return await waking(request, f"v1/llms/{llm_id}/{action}")

    @app.post("/v1/engines/{engine_id}/{action}")
    async def engine_action(engine_id: str, action: str, request: Request) -> Response:
        if engine_id not in PROFILES:
            return JSONResponse({"detail": f"Unknown engine '{engine_id}'. Use one of: {', '.join(PROFILES)}"}, status_code=404)
        if action in ("enable", "load"):
            if too_many_enabled(gateway.enabled, engine_id):
                return JSONResponse({"detail": limit_message(gateway.enabled, engine_id)}, status_code=409)
            gateway.last_engines.pop(engine_id, None)  # forget an old load error: it is retried
        if action == "enable" and engine_id not in gateway.enabled:
            gateway.enabled.append(engine_id)
        elif action == "disable" and engine_id in gateway.enabled:
            gateway.enabled.remove(engine_id)
        elif action == "default":
            gateway.default_engine = engine_id
        elif action == "load":
            if engine_id not in gateway.enabled:
                gateway.enabled.append(engine_id)
        elif action not in LOCAL_ENGINE_ACTIONS:
            return JSONResponse({"detail": f"Unknown action '{action}'"}, status_code=404)

        if action in LOCAL_ENGINE_ACTIONS and not gateway.running:
            data = gateway.sleeping_health()
            if action == "default":
                return JSONResponse({"default_engine": gateway.default_engine, "engines": data["engines"]})
            return JSONResponse(gateway.engine_report(engine_id))
        return await waking(request, f"v1/engines/{engine_id}/{action}", engine_id if action == "load" else None)

    async def waking(request: Request, path: str, engine_id: Optional[str] = None, stream: bool = False) -> Response:
        # Before anything is counted: a client that leaves during the upload raises here.
        body = await request.body()
        gateway.in_flight += 1
        gateway.last_activity = time.monotonic()
        if engine_id:
            gateway.waking.add(engine_id)
        finished = False

        def done() -> None:
            nonlocal finished
            if not finished:
                finished = True
                gateway.in_flight -= 1
                gateway.last_activity = time.monotonic()

        try:
            await gateway.ensure_worker()
            if stream:
                return await forward_stream(request, path, body, done)  # done() when the stream ends
            response = await forward(request, path, body)
        except (WorkerUnavailable, httpx.HTTPError) as exc:
            response = worker_error(exc)
        except BaseException:  # the client left, or the worker could not be started at all
            done()
            raise
        done()
        return response

    @app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
    async def everything_else(path: str, request: Request) -> Response:
        if request.method == "GET":  # reads never start the worker
            if not gateway.running:
                return JSONResponse({"detail": "Not found"}, status_code=404)
            try:
                return await forward(request, path)
            except httpx.HTTPError as exc:
                return worker_error(exc)
        # A speech engine that is turned off never wakes the worker.
        first = path.split("/", 1)[0]
        if first in PROFILES and first not in gateway.enabled:
            profile = PROFILES[first]
            return JSONResponse(
                {
                    "detail": (
                        f"{profile.name} is turned off. Turn it on in Navo > Settings > Speech engines, "
                        f"or POST /v1/engines/{first}/load"
                    )
                },
                status_code=503,
            )
        if path.endswith("chat/completions"):
            if path != "v1/chat/completions" and first not in LLM_PROFILES:
                return JSONResponse(
                    {"detail": f"Unknown language model '{first}'. Use one of: {', '.join(LLM_PROFILES)}"}, status_code=404
                )
            # A language model that is not downloaded never wakes the worker (the speech models stay).
            if first in LLM_PROFILES and cached_snapshot(gateway.llm_models[first]) is None:
                profile = LLM_PROFILES[first]
                return JSONResponse(
                    {
                        "detail": (
                            f"{profile.name} is not downloaded yet. Download it in Navo > Settings > AI writing, or run: "
                            f"python -m navo_engine.download --model {gateway.llm_models[first]}"
                        )
                    },
                    status_code=503,
                )
            return await waking(request, path, stream=True)
        engine_id = first if first in PROFILES else request.query_params.get("engine")
        if path == "v1/wake" and engine_id is None:
            engine_id = gateway.default_engine
        return await waking(request, path, engine_id if engine_id in PROFILES else None)

    return app


def main(argv: Optional[list[str]] = None) -> None:
    parser = argparse.ArgumentParser(description="Navo local engine (gateway; models load on demand)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--idle-minutes",
        type=float,
        default=DEFAULT_IDLE_MINUTES,
        help="Free a model's memory after this many minutes without use (0 keeps models loaded)",
    )
    add_model_arguments(parser)
    args = parser.parse_args(argv)
    check_engine_limit(parser, args.engines)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )
    logging.getLogger("httpx").setLevel(logging.WARNING)  # one line per forwarded request is noise
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        log.warning("Binding to %s exposes the engine beyond this Mac", args.host)
    if args.parent_pid:
        watch_parent(args.parent_pid)
    if (args.default_engine or "cohere").lower() not in PROFILES:
        parser.error(f"unknown default engine '{args.default_engine}'")

    gateway = Gateway(args, idle_minutes=max(0.0, args.idle_minutes))
    log.info(
        "Navo engine on %s:%d, models %s",
        args.host,
        args.port,
        "stay loaded" if gateway.idle_minutes <= 0 else f"sleep after {gateway.idle_minutes:g} min idle",
    )

    import uvicorn

    uvicorn.run(create_gateway_app(gateway), host=args.host, port=args.port, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
