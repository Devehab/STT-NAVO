"""Navo model worker: the process that holds the models (127.0.0.1 or a Unix socket only).

The Navo app does not start this directly. It starts the gateway (``python -m navo_engine``),
which starts this worker when a model is needed and stops it when every model has been idle,
so the memory goes back to macOS. Run it directly to keep models loaded without the gateway:

    python -m navo_engine.server --port 7861 --engines whisper,audar

At most two speech engines are on at once (MAX_ENABLED_ENGINES): turning on a third answers
409 until one of the others is turned off.

A language model (Gemma, Llama) is never in memory together with a speech engine or the
cleanup model: whichever a request needs is loaded after the other kind has left (llms.py).

Endpoints
---------
GET  /health                              worker, speech engines and cleanup model status
GET  /v1/engines                          the speech engines and their state
GET  /{engine}/health                     one speech engine
POST /v1/engines/{engine}/enable          allow it to load on demand (asleep until used); 409 if two are on
POST /v1/engines/{engine}/disable         turn it off: free its memory and refuse requests
POST /v1/engines/{engine}/load            turn it on and load it now; 409 if two others are on
POST /v1/engines/{engine}/unload          free its memory now; the next request loads it again
POST /v1/engines/{engine}/default         make it the engine for requests that do not name one
POST /v1/cleanup/load | /v1/cleanup/unload   the cleanup LLM
POST /v1/wake?engine=cohere&cleanup=true  start loading ahead of a request (returns at once)
POST /{engine}/v1/audio/transcriptions    OpenAI-compatible transcription with one engine
POST /v1/audio/transcriptions             same, engine picked by `model`, else the default engine
POST /v1/audio/compare                    one file through several engines, results side by side
POST /{llm}/v1/chat/completions           OpenAI-compatible chat with a language model (gemma, llama),
                                          "stream": true for server-sent events
POST /v1/chat/completions                 same when `model` names a language model, else the cleanup model
GET  /v1/llms                             the language models and their state
POST /v1/llms/{llm}/load | /unload        load one ahead of a request, or free it now
POST /v1/llms/unload                      free every language model now
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Optional

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile  # noqa: E402
from fastapi.responses import PlainTextResponse, StreamingResponse  # noqa: E402
from pydantic import BaseModel, Field  # noqa: E402

from . import DEFAULT_PORT, SAMPLE_RATE, __version__, package_version  # noqa: E402
from .asr import ASRService, AudioDecodeError, EngineNotReady, load_audio, normalize_language  # noqa: E402
from .engines import ALL_LANGUAGES, PROFILES, limit_message, lookup, too_many_enabled  # noqa: E402
from .llm import LLMService, LLMUnavailable  # noqa: E402
from .llms import DEFAULT_KEEP_ALIVE, LLM_PROFILES, Completion, LanguageModel, PromptTooLong, lookup_llm  # noqa: E402
from .options import (  # noqa: E402
    add_model_arguments,
    check_engine_limit,
    engine_list_arg,
    llm_overrides,
    model_overrides,
    watch_parent,
)

log = logging.getLogger("navo.engine")

MAX_UPLOAD_BYTES = 200 * 1024 * 1024


class ChatMessage(BaseModel):
    role: str = "user"
    content: Any = ""


class ChatRequest(BaseModel):
    model: Optional[str] = None
    messages: list[ChatMessage] = Field(default_factory=list)
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    top_k: Optional[int] = None
    max_tokens: Optional[int] = None
    max_completion_tokens: Optional[int] = None  # OpenAI's newer name for max_tokens
    stop: Optional[Any] = None  # a string or a list of strings
    stream: bool = False
    repetition_penalty: Optional[float] = None
    # Seconds the language model stays in memory after this answer (0: leave at once).
    keep_alive: Optional[float] = None


class Engine:
    """Bundles the services with the single worker thread that runs all model code.

    One thread for every model keeps MLX on one thread and means two engines never
    compete for the GPU: requests are answered in order.

    The same thread keeps the memory rule: a language model (``llms``) is never loaded
    together with a speech engine or the cleanup model. The methods whose names start with
    an underscore run on that thread and free the other kind before they load anything.
    """

    def __init__(
        self,
        asr: ASRService | dict[str, ASRService],
        llm: LLMService,
        host: str = "127.0.0.1",
        port: int = 0,
        default_engine: Optional[str] = None,
        enabled: Optional[list[str]] = None,
        llms: Optional[dict[str, LanguageModel]] = None,
        keep_alive: float = DEFAULT_KEEP_ALIVE,
    ):
        self.engines: dict[str, ASRService] = asr if isinstance(asr, dict) else {asr.engine_id: asr}
        self.default_engine = default_engine if default_engine in self.engines else next(iter(self.engines))
        for engine_id, service in self.engines.items():
            service.set_enabled(enabled is None or engine_id in enabled)
        self.llm = llm
        self.llms: dict[str, LanguageModel] = llms or {}
        self.keep_alive = keep_alive
        self.host = host
        self.port = port
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="navo-model")
        self.started_at = time.time()

    @property
    def asr(self) -> ASRService:
        """The default engine (kept for callers that know only one engine)."""
        return self.engines[self.default_engine]

    def start_loading(self, engine_ids: Optional[list[str]] = None, preload_llm: bool = True) -> None:
        for engine_id in engine_ids if engine_ids is not None else [self.default_engine]:
            self.queue_load(engine_id)
        if preload_llm:
            self.queue_llm_load()

    def queue_load(self, engine_id: str) -> None:
        """Turns the engine on and loads it on the model thread (no-op when loaded or loading)."""
        service = self.engines[engine_id]
        service.set_enabled(True)
        if service.status in ("ready", "loading"):
            return
        service.status, service.error = "loading", None
        self.worker.submit(self._load_speech, service)

    def queue_llm_load(self) -> None:
        if self.llm.model_id is None:
            self.worker.submit(self._preload_cleanup)

    async def run(self, fn, *args):
        return await asyncio.wrap_future(self.worker.submit(fn, *args))

    async def run_speech(self, service: ASRService, fn, *args):
        """Runs a transcription, loading the engine first if a language model had taken its place."""
        return await self.run(self._speech_job, service, fn, *args)

    # On the model thread: one kind of model in memory at a time.

    def _free_llms(self) -> None:
        for model in self.llms.values():
            if model.loaded:
                model.unload()

    def _free_for_llm(self, keep: LanguageModel) -> None:
        for service in self.engines.values():
            if service.backend is not None:
                service.unload()  # asleep: the next transcription loads it again
        self.llm.unload()
        for model in self.llms.values():
            if model is not keep and model.loaded:
                model.unload()

    def _load_speech(self, service: ASRService) -> None:
        self._free_llms()
        service.load()

    def _speech_job(self, service: ASRService, fn, *args):
        if service.backend is None and service.enabled:
            self._load_speech(service)
        return fn(*args)

    def _preload_cleanup(self) -> None:
        self._free_llms()
        self.llm.preload()

    def _cleanup_chat(self, *args):
        self._free_llms()
        return self.llm.chat(*args)

    def _llm_load(self, model: LanguageModel) -> None:
        if not model.loaded:
            if not model.downloaded:
                model.load()  # raises: not downloaded. Nothing else leaves memory for it
            self._free_for_llm(model)
        model.load()

    def _stay(self, keep_alive: Optional[float]) -> float:
        """Seconds a model stays for a request that is on its way: never less than half a minute."""
        value = self.keep_alive if keep_alive is None else keep_alive
        if value != value:  # NaN
            value = self.keep_alive
        return value if value < 0 else max(value, 30.0)

    def _llm_prepare(self, model: LanguageModel, messages: list[dict], max_tokens: Optional[int]) -> int:
        """Loads the model and checks that the request fits. Returns the prompt's token count."""
        self._llm_load(model)
        # Stays for the request that follows, and leaves on its own if that request never comes.
        self._llm_rest(model, self._stay(None))
        tokens = len(model.prompt_ids(messages))
        model.output_budget(tokens, max_tokens)
        return tokens

    def _llm_generate(self, model: LanguageModel, keep_alive: Optional[float], messages: list[dict], options: dict) -> Completion:
        self._llm_load(model)  # again: a speech request may have run in between
        try:
            return model.generate(messages, **options)
        finally:
            self._llm_rest(model, self.keep_alive if keep_alive is None else keep_alive)

    def _llm_rest(self, model: LanguageModel, keep_alive: float) -> None:
        """After an answer: leave memory now, after ``keep_alive`` seconds, or stay (negative)."""
        if not model.loaded:
            return
        if keep_alive != keep_alive:  # NaN
            keep_alive = self.keep_alive
        keep_alive = min(keep_alive, 86_400.0)
        if keep_alive == 0:
            model.unload()
        elif keep_alive < 0:
            model.expires_at = None
        else:
            model.expires_at = time.monotonic() + keep_alive
            timer = threading.Timer(keep_alive + 0.05, lambda: self.worker.submit(self._llm_expire, model))
            timer.daemon = True
            timer.start()

    def _llm_expire(self, model: LanguageModel) -> None:
        if model.loaded and model.expires_at is not None and time.monotonic() >= model.expires_at:
            model.unload()

    @property
    def enabled_ids(self) -> list[str]:
        return [engine_id for engine_id, service in self.engines.items() if service.enabled]


def create_app(engine: Engine) -> FastAPI:
    app = FastAPI(title="Navo Engine", version=__version__)

    def service_for(engine_id: Optional[str]) -> ASRService:
        if engine_id is None:
            return engine.asr
        service = engine.engines.get(engine_id.lower())
        if service is None:
            known = ", ".join(engine.engines)
            raise HTTPException(status_code=404, detail=f"Unknown engine '{engine_id}'. Use one of: {known}")
        return service

    def make_available(service: ASRService) -> None:
        """Loads a sleeping engine for the request that is about to be queued behind the load."""
        if service.status == "off":
            raise HTTPException(
                status_code=503,
                detail=(
                    f"{service.name} is turned off. Turn it on in Navo > Settings > Speech engines, "
                    f"or POST /v1/engines/{service.engine_id}/load"
                ),
            )
        if service.status == "error":
            raise HTTPException(status_code=503, detail=f"{service.name} failed to load: {service.error}")
        if service.status == "asleep":
            log.info("%s is asleep, loading it for a request", service.name)
            engine.queue_load(service.engine_id)

    async def save_upload(file: UploadFile) -> str:
        payload = await file.read()
        if not payload:
            raise HTTPException(status_code=400, detail="Empty audio file")
        if len(payload) > MAX_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="Audio file is too large")
        suffix = Path(file.filename or "audio.wav").suffix or ".wav"
        fd, tmp_path = tempfile.mkstemp(prefix="navo-", suffix=suffix)
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
        return tmp_path

    def parse_language(value: Optional[str]) -> str:
        try:
            return normalize_language(value, ALL_LANGUAGES)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    def engine_list() -> list[dict]:
        return [{**service.info(), "default": engine_id == engine.default_engine} for engine_id, service in engine.engines.items()]

    def llm_list() -> list[dict]:
        return [model.info() for model in engine.llms.values()]

    def llm_for(llm_id: str) -> LanguageModel:
        model = engine.llms.get(llm_id.lower())
        if model is None:
            known = ", ".join(engine.llms) or "none"
            raise HTTPException(status_code=404, detail=f"Unknown language model '{llm_id}'. Use one of: {known}")
        return model

    @app.get("/health")
    def health() -> dict:
        asr = engine.asr
        return {
            "service": "navo-engine",
            "role": "worker",
            "version": __version__,
            "default_engine": engine.default_engine,
            "engines": engine_list(),
            # The fields below describe the default engine, for clients written for one engine.
            "status": asr.status,
            "backend": asr.backend_name,
            "model": asr.model_id,
            "error": asr.error,
            "load_seconds": asr.load_seconds,
            "uptime_seconds": round(time.time() - engine.started_at, 1),
            "pid": os.getpid(),
            "host": engine.host,
            "port": engine.port,
            "offline": os.environ.get("HF_HUB_OFFLINE") == "1",
            "device": asr.device,
            "model_path": asr.model_path,
            "model_bytes": asr.model_bytes,
            "transcriptions": sum(s.transcriptions for s in engine.engines.values()),
            "last_processing_ms": asr.last_processing_ms,
            "llm": engine.llm.info(),  # the small cleanup model
            "llms": llm_list(),  # the language models that summarize and rewrite
            "mlx_lm_version": package_version("mlx-lm"),  # Gemma 4 needs 0.32 or newer
        }

    @app.get("/v1/engines")
    def engines() -> dict:
        return {"default_engine": engine.default_engine, "engines": engine_list()}

    @app.get("/v1/llms")
    def llms() -> dict:
        return {"llms": llm_list()}

    @app.get("/{engine_id}/health")
    def engine_health(engine_id: str) -> dict:
        if engine_id.lower() in engine.llms:
            return engine.llms[engine_id.lower()].info()
        return {**service_for(engine_id).info(), "default": engine_id == engine.default_engine}

    def check_room(service: ASRService) -> None:
        """Refuses to turn on a third engine: at most two are on at once."""
        if too_many_enabled(engine.enabled_ids, service.engine_id):
            raise HTTPException(status_code=409, detail=limit_message(engine.enabled_ids, service.engine_id))

    @app.post("/v1/engines/{engine_id}/enable")
    def enable_engine(engine_id: str) -> dict:
        service = service_for(engine_id)
        check_room(service)
        service.set_enabled(True)
        return service.info()

    @app.post("/v1/engines/{engine_id}/disable")
    async def disable_engine(engine_id: str) -> dict:
        service = service_for(engine_id)
        service.set_enabled(False)
        # Always on the model thread: it waits for a load or requests already queued, also a
        # load that a waiting transcription is about to start.
        await engine.run(service.unload)
        return service.info()

    @app.post("/v1/engines/{engine_id}/load")
    def load_engine(engine_id: str) -> dict:
        service = service_for(engine_id)
        check_room(service)
        engine.queue_load(service.engine_id)
        return service.info()

    @app.post("/v1/engines/{engine_id}/unload")
    async def unload_engine(engine_id: str) -> dict:
        service = service_for(engine_id)
        if service.status not in ("off", "asleep"):
            await engine.run(service.unload)
        return service.info()

    @app.post("/v1/engines/{engine_id}/default")
    def set_default(engine_id: str) -> dict:
        service = service_for(engine_id)
        engine.default_engine = service.engine_id
        return {"default_engine": engine.default_engine, "engines": engine_list()}

    @app.post("/v1/llms/unload")
    async def unload_llms() -> dict:
        await engine.run(engine._free_llms)
        return {"llms": llm_list()}

    @app.post("/v1/llms/{llm_id}/load")
    async def load_llm(llm_id: str) -> dict:
        """Loads a language model ahead of a request. The speech engines leave memory first."""
        model = llm_for(llm_id)

        def load() -> None:
            engine._llm_load(model)
            engine._llm_rest(model, engine._stay(None))

        try:
            await engine.run(load)
        except LLMUnavailable as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        return model.info()

    @app.post("/v1/llms/{llm_id}/unload")
    async def unload_llm(llm_id: str) -> dict:
        model = llm_for(llm_id)
        await engine.run(model.unload)  # on the model thread: after a load or an answer under way
        return model.info()

    @app.post("/v1/cleanup/load")
    def load_cleanup() -> dict:
        engine.queue_llm_load()
        return engine.llm.info()

    @app.post("/v1/cleanup/unload")
    async def unload_cleanup() -> dict:
        await engine.run(engine.llm.unload)
        return engine.llm.info()

    @app.post("/v1/wake")
    def wake(engine_id: Optional[str] = Query(None, alias="engine"), cleanup: bool = False) -> dict:
        """Starts loading ahead of a request, for example when the user starts talking."""
        service = service_for(engine_id)
        if service.status == "asleep":
            engine.queue_load(service.engine_id)
        if cleanup:
            engine.queue_llm_load()
        return {"engine": service.info(), "llm": engine.llm.info()}

    async def transcribe(
        service: ASRService,
        file: UploadFile,
        language: Optional[str],
        response_format: Optional[str],
    ):
        lang = parse_language(language)
        try:
            service.check_language(lang)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        make_available(service)
        tmp_path = await save_upload(file)
        try:
            started = time.perf_counter()
            result = await engine.run_speech(service, service.transcribe_file, tmp_path, lang)
            elapsed = int((time.perf_counter() - started) * 1000)
            log.info("%s: %.1f s of audio (%s) in %d ms", service.engine_id, result.audio_seconds, lang, elapsed)
            if (response_format or "json").strip().lower() == "text":
                return PlainTextResponse(result.text)
            return {
                "text": result.text,
                "language": lang,
                "duration": round(result.audio_seconds, 2),
                "engine": service.engine_id,
                "model": service.model_id,
                "backend": service.backend_name,
                "processing_ms": elapsed,
            }
        except HTTPException:
            raise
        except EngineNotReady as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except AudioDecodeError as exc:
            raise HTTPException(status_code=415, detail=str(exc)) from exc
        except Exception as exc:
            log.exception("Transcription failed")
            raise HTTPException(status_code=500, detail=f"Transcription failed: {exc}") from exc
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    @app.post("/v1/audio/transcriptions")
    async def transcriptions(
        file: UploadFile = File(...),
        language: Optional[str] = Form("ar"),
        model: Optional[str] = Form(None),  # an engine name picks that engine; anything else means the default
        response_format: Optional[str] = Form("json"),  # "json" (default) or "text"
    ):
        engine_id = lookup(model, {k: s.model_id for k, s in engine.engines.items()})
        return await transcribe(service_for(engine_id), file, language, response_format)

    @app.post("/{engine_id}/v1/audio/transcriptions")
    async def engine_transcriptions(
        engine_id: str,
        file: UploadFile = File(...),
        language: Optional[str] = Form("ar"),
        model: Optional[str] = Form(None),  # accepted for OpenAI compatibility, ignored: the path names the engine
        response_format: Optional[str] = Form("json"),
    ):
        return await transcribe(service_for(engine_id), file, language, response_format)

    @app.post("/v1/audio/compare")
    async def compare(
        file: UploadFile = File(...),
        language: Optional[str] = Form("ar"),
        engines: Optional[str] = Form(None),  # comma separated, default: every engine that is on
    ):
        lang = parse_language(language)
        if engines:
            selected = [service_for(name.strip()) for name in engines.split(",") if name.strip()]
        else:
            selected = [s for s in engine.engines.values() if s.status != "off"]
        if not selected:
            raise HTTPException(status_code=503, detail="No speech engine is on. Turn one on in Navo > Settings.")
        for service in selected:
            if service.status == "asleep":
                engine.queue_load(service.engine_id)
        tmp_path = await save_upload(file)
        try:
            try:
                audio = await engine.run(load_audio, tmp_path)
            except AudioDecodeError as exc:
                raise HTTPException(status_code=415, detail=str(exc)) from exc
            results = []
            for service in selected:
                entry: dict[str, Any] = {
                    "engine": service.engine_id,
                    "name": service.name,
                    "model": service.model_id,
                    "backend": service.backend_name,
                    "text": None,
                    "processing_ms": None,
                    "error": None,
                }
                if service.status in ("off", "error"):
                    entry["error"] = f"{service.name} is {service.status}" + (f": {service.error}" if service.error else "")
                elif lang not in service.languages:
                    entry["error"] = f"{service.name} does not support language '{lang}'"
                else:
                    started = time.perf_counter()
                    try:
                        entry["text"] = await engine.run_speech(service, service.transcribe_audio, audio, lang)
                        entry["backend"] = service.backend_name
                    except EngineNotReady as exc:
                        entry["error"] = str(exc)
                    except Exception as exc:
                        log.exception("Compare: %s failed", service.engine_id)
                        entry["error"] = f"Transcription failed: {exc}"
                    entry["processing_ms"] = int((time.perf_counter() - started) * 1000)
                results.append(entry)
            return {"language": lang, "duration": round(len(audio) / SAMPLE_RATE, 2), "results": results}
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    def chat_body(model_name: str, text: str, finish_reason: str = "stop") -> dict:
        return {
            "id": f"chatcmpl-navo-{uuid.uuid4().hex[:12]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model_name,
            "choices": [
                {"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": finish_reason}
            ],
        }

    async def cleanup_chat(request: ChatRequest) -> dict:
        """The small cleanup model, as before the language models existed."""
        messages = [m.model_dump() for m in request.messages]
        temperature = 0.2 if request.temperature is None else request.temperature
        max_tokens = request.max_tokens or request.max_completion_tokens or 1024
        try:
            text = await engine.run(engine._cleanup_chat, messages, request.model, temperature, max_tokens)
        except LLMUnavailable as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except Exception as exc:
            log.exception("Chat completion failed")
            engine.llm.error = str(exc)
            raise HTTPException(status_code=500, detail=f"Local LLM failed: {exc}") from exc
        return chat_body(engine.llm.model_id, text)

    async def llm_chat(model: LanguageModel, request: ChatRequest):
        """A language model answers: first the other models leave memory, then it loads and writes."""
        messages = [m.model_dump() for m in request.messages]
        max_tokens = request.max_tokens if request.max_tokens is not None else request.max_completion_tokens
        stop = [request.stop] if isinstance(request.stop, str) else [str(s) for s in request.stop] if isinstance(request.stop, list) else []
        options = {
            "temperature": 0.3 if request.temperature is None else max(0.0, request.temperature),
            "top_p": 0.95 if request.top_p is None else request.top_p,
            "top_k": request.top_k or 0,
            "max_tokens": max_tokens,
            "repetition_penalty": request.repetition_penalty,
            "stop": stop,
        }
        try:
            await engine.run(engine._llm_prepare, model, messages, max_tokens)
        except LLMUnavailable as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except PromptTooLong as exc:
            raise HTTPException(status_code=413, detail=str(exc)) from exc
        except Exception as exc:
            log.exception("%s could not read the request", model.name)
            raise HTTPException(status_code=500, detail=f"{model.name} failed: {exc}") from exc

        if request.stream:
            return stream_chat(model, request, messages, options)
        try:
            completion = await engine.run(engine._llm_generate, model, request.keep_alive, messages, options)
        except LLMUnavailable as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        except PromptTooLong as exc:
            raise HTTPException(status_code=413, detail=str(exc)) from exc
        except Exception as exc:
            log.exception("%s failed", model.name)
            raise HTTPException(status_code=500, detail=f"{model.name} failed: {exc}") from exc
        finish = "length" if completion.finish_reason == "length" else "stop"
        body = chat_body(model.model_id, completion.text, finish)
        body["usage"] = completion.usage()
        body["navo"] = {"llm": model.llm_id, **completion.stats()}
        log.info(
            "%s: %d + %d tokens in %.1f s", model.llm_id, completion.prompt_tokens, completion.completion_tokens, completion.seconds
        )
        return body

    def stream_chat(model: LanguageModel, request: ChatRequest, messages: list[dict], options: dict) -> StreamingResponse:
        """The answer as server-sent events in OpenAI's chunk format, written piece by piece."""
        loop = asyncio.get_running_loop()
        queue: asyncio.Queue = asyncio.Queue()
        cancel = threading.Event()
        chat_id = f"chatcmpl-navo-{uuid.uuid4().hex[:12]}"
        created = int(time.time())

        def put(kind: str, value: Any) -> None:
            loop.call_soon_threadsafe(queue.put_nowait, (kind, value))

        def job() -> None:
            if cancel.is_set():
                return  # the client left while this waited in line: nothing to load or write
            try:
                extra = {"on_text": lambda piece: put("text", piece), "cancelled": cancel.is_set}
                put("done", engine._llm_generate(model, request.keep_alive, messages, {**options, **extra}))
            except Exception as exc:  # reported in the stream: the status line is already sent
                log.exception("%s failed", model.name)
                put("error", exc)

        def chunk(delta: dict, finish: Optional[str] = None, **extra: Any) -> str:
            body = {
                "id": chat_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model.model_id,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
                **extra,
            }
            return f"data: {json.dumps(body, ensure_ascii=False)}\n\n"

        async def events():
            engine.worker.submit(job)
            try:
                yield chunk({"role": "assistant", "content": ""})
                while True:
                    kind, value = await queue.get()
                    if kind == "text":
                        yield chunk({"content": value})
                    elif kind == "done":
                        finish = "length" if value.finish_reason == "length" else "stop"
                        yield chunk({}, finish, usage=value.usage(), navo={"llm": model.llm_id, **value.stats()})
                        break
                    else:
                        yield f"data: {json.dumps({'error': {'message': f'{model.name} failed: {value}'}})}\n\n"
                        break
                yield "data: [DONE]\n\n"
            finally:
                cancel.set()  # the client went away: stop writing

        return StreamingResponse(
            events(), media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}
        )

    @app.post("/v1/chat/completions")
    async def chat_completions(request: ChatRequest):
        if not request.messages:
            raise HTTPException(status_code=400, detail="messages is required")
        llm_id = lookup_llm(request.model, {k: m.model_id for k, m in engine.llms.items()})
        if llm_id in engine.llms:
            return await llm_chat(engine.llms[llm_id], request)
        if request.stream:
            raise HTTPException(status_code=400, detail="The cleanup model does not stream. Use model 'gemma' or 'llama'.")
        return await cleanup_chat(request)

    @app.post("/{llm_id}/v1/chat/completions")
    async def llm_chat_completions(llm_id: str, request: ChatRequest):
        if not request.messages:
            raise HTTPException(status_code=400, detail="messages is required")
        return await llm_chat(llm_for(llm_id), request)

    return app


def build_engines(args: argparse.Namespace) -> dict[str, ASRService]:
    models = model_overrides(args)
    return {
        profile.id: ASRService(
            models[profile.id],
            backend=args.backend if profile.family == "cohere_asr" else "auto",
            allow_download=args.allow_download,
            engine_id=profile.id,
            name=profile.name,
            family=profile.family,
            languages=profile.languages,
        )
        for profile in PROFILES.values()
    }


def build_llms(args: argparse.Namespace) -> dict[str, LanguageModel]:
    models = llm_overrides(args)
    return {
        profile.id: LanguageModel(profile, models[profile.id], context_tokens=args.llm_context)
        for profile in LLM_PROFILES.values()
    }


def main(argv: Optional[list[str]] = None) -> None:
    parser = argparse.ArgumentParser(description="Navo model worker (keeps models loaded; the gateway adds sleep)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--uds", default=None, help="Listen on this Unix socket instead of host and port")
    add_model_arguments(parser)
    parser.add_argument(
        "--preload",
        type=engine_list_arg,
        default=None,
        help="Engines to load at startup (default: every engine that is on). 'none' loads nothing until a request",
    )
    args = parser.parse_args(argv)
    check_engine_limit(parser, args.engines)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )
    if not args.uds and args.host not in ("127.0.0.1", "localhost", "::1"):
        log.warning("Binding to %s exposes the engine beyond this Mac", args.host)
    if args.parent_pid:
        watch_parent(args.parent_pid)

    default = (args.default_engine or (args.engines[0] if args.engines else "cohere")).lower()
    if default not in PROFILES:
        parser.error(f"unknown default engine '{default}'")
    preload = args.engines if args.preload is None else [e for e in args.preload if e in args.engines]

    engine = Engine(
        build_engines(args),
        LLMService(args.llm_model),
        host=args.host,
        port=args.port,
        default_engine=default,
        enabled=args.engines,
        llms=build_llms(args),
        keep_alive=args.llm_keep_alive,
    )
    engine.start_loading(preload, preload_llm=not args.no_preload_llm)

    import uvicorn

    app = create_app(engine)
    if args.uds:
        uvicorn.run(app, uds=args.uds, log_level="warning", access_log=False)
    else:
        uvicorn.run(app, host=args.host, port=args.port, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
