"""Audar and Qwen3-ASR 1.7B on MLX with tiny random checkpoints laid out like the real ones.

Runs where MLX and mlx-audio are installed (the Navo engine venv, or Linux with mlx[cpu]).

    cd engine && python -m pytest -q tests/test_qwen3_mlx.py
"""

import json
import sys
from pathlib import Path

import numpy as np
import pytest

mx = pytest.importorskip("mlx.core")
pytest.importorskip("mlx_audio.stt.models.qwen3_asr")
tokenizers = pytest.importorskip("tokenizers")

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from navo_engine.asr import ASRService, Qwen3MLXBackend  # noqa: E402

VOCAB = 10240  # over 10k, so mlx-audio treats it as ASR (not the forced aligner), as with the real model

REMOTE_CONFIG = """
try:
    from transformers import PreTrainedConfig as _Base
except ImportError:
    from transformers import PretrainedConfig as _Base


class Qwen3ASRConfig(_Base):
    model_type = "qwen3_asr"

    def __init__(self, thinker_config=None, support_languages=None, **kwargs):
        super().__init__(**kwargs)  # transformers 5 validates here, before thinker_config exists
        self.thinker_config = thinker_config
        self.support_languages = support_languages

    def get_text_config(self, decoder=False):
        return self.thinker_config.get_text_config()
"""


def build_checkpoint(out, tied=False, languages=("English", "Arabic")):
    """Audar's layout (untied head, custom configuration code), or with `tied` the base
    Qwen3-ASR's (the head shares the embeddings and is not in the checkpoint)."""
    from mlx.utils import tree_flatten
    from mlx_audio.stt.models.qwen3_asr.config import ModelConfig
    from mlx_audio.stt.models.qwen3_asr.qwen3_asr import Model
    from tokenizers import Tokenizer, decoders, models, pre_tokenizers, trainers

    special = ["<|endoftext|>", "<|im_start|>", "<|im_end|>", "<|audio_start|>", "<|audio_end|>", "<|audio_pad|>", "<asr_text>"]
    tok = Tokenizer(models.BPE())
    tok.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    tok.decoder = decoders.ByteLevel()
    trainer = trainers.BpeTrainer(vocab_size=300, special_tokens=special, initial_alphabet=pre_tokenizers.ByteLevel.alphabet())
    tok.train_from_iterator(["language Arabic English system user assistant مرحبا hello"] * 20, trainer)
    tokenizer_config = {
        "tokenizer_class": "Qwen2Tokenizer", "processor_class": "Qwen3ASRProcessor",
        "eos_token": "<|im_end|>", "pad_token": "<|endoftext|>"}
    if tied:
        # Like mlx-community's Qwen3-ASR repo: vocab.json and merges.txt, the special tokens in
        # tokenizer_config.json, and no tokenizer.json.
        tok.model.save(str(out))
        tokenizer_config["added_tokens_decoder"] = {
            str(tok.token_to_id(t)): {"content": t, "special": True, "lstrip": False, "rstrip": False,
                                      "normalized": False, "single_word": False}
            for t in special
        }
    else:
        tok.save(str(out / "tokenizer.json"))
    (out / "tokenizer_config.json").write_text(json.dumps(tokenizer_config))
    (out / "preprocessor_config.json").write_text(json.dumps({
        "feature_extractor_type": "WhisperFeatureExtractor", "feature_size": 128, "hop_length": 160, "n_fft": 400,
        "chunk_length": 30, "n_samples": 480000, "nb_max_frames": 3000, "padding_value": 0.0, "sampling_rate": 16000,
        "return_attention_mask": True, "processor_class": "Qwen3ASRProcessor",
        "auto_map": {"AutoProcessor": "processing_audar_asr.Qwen3ASRProcessor"}}))
    config = {
        "model_type": "qwen3_asr",
        "tie_word_embeddings": tied,
        "support_languages": list(languages),
        "thinker_config": {
            "audio_config": {"d_model": 32, "encoder_layers": 1, "encoder_attention_heads": 2, "encoder_ffn_dim": 64,
                             "num_mel_bins": 128, "output_dim": 32, "downsample_hidden_size": 8},
            "text_config": {"hidden_size": 32, "intermediate_size": 64, "num_hidden_layers": 1,
                            "num_attention_heads": 2, "num_key_value_heads": 1, "head_dim": 16,
                            "vocab_size": VOCAB, "tie_word_embeddings": tied},
            "audio_token_id": tok.token_to_id("<|audio_pad|>"),
            "audio_start_token_id": tok.token_to_id("<|audio_start|>"),
            "audio_end_token_id": tok.token_to_id("<|audio_end|>"),
        },
    }
    if not tied:
        # Like Audar's repo: custom configuration code written for transformers 4.57, which fails on 5.x.
        (out / "configuration_audar_asr.py").write_text(REMOTE_CONFIG)
        config["auto_map"] = {"AutoConfig": "configuration_audar_asr.Qwen3ASRConfig"}
    (out / "config.json").write_text(json.dumps(config))
    model = Model(ModelConfig.from_dict(config))
    weights = {}
    for key, value in tree_flatten(model.parameters()):
        if "conv2d" in key and key.endswith("weight") and value.ndim == 4:
            value = value.transpose(0, 3, 1, 2)  # PyTorch layout, as published
        weights["thinker." + key] = value.astype(mx.bfloat16)
    head = None
    if not tied:
        head = mx.random.normal((VOCAB, 32)).astype(mx.bfloat16)
        weights["thinker.lm_head.weight"] = head
    else:
        weights = {k: v for k, v in weights.items() if "lm_head" not in k}
    mx.save_safetensors(str(out / "model.safetensors"), weights)
    return out, head


@pytest.fixture(scope="module")
def checkpoint(tmp_path_factory):
    return build_checkpoint(tmp_path_factory.mktemp("tiny-audar"))


@pytest.fixture(scope="module")
def qwen3_checkpoint(tmp_path_factory):
    names = [name for name in Qwen3MLXBackend.LANGUAGE_NAMES.values() if name]
    return build_checkpoint(tmp_path_factory.mktemp("tiny-qwen3"), tied=True, languages=names)[0]


def test_repo_configuration_code_is_never_run(checkpoint):
    import transformers

    path, _ = checkpoint
    before = transformers.AutoTokenizer.__dict__.get("from_pretrained")
    backend = Qwen3MLXBackend(path)  # would raise AttributeError: no attribute 'thinker_config'
    assert backend._model._model._tokenizer.convert_tokens_to_ids("<|im_end|>") is not None
    assert transformers.AutoTokenizer.__dict__.get("from_pretrained") is before


def test_untied_output_head_is_restored(checkpoint):
    path, head = checkpoint
    backend = Qwen3MLXBackend(path)
    loaded = backend._model._model.lm_head.weight
    assert mx.allclose(loaded.astype(mx.float32), head.astype(mx.float32)).item()


def test_long_audio_is_chunked_and_bounded(checkpoint):
    path, _ = checkpoint
    service = ASRService(str(path), engine_id="audar", name="Audar ASR V1 Turbo", family="qwen3_asr")
    service.load()
    assert service.status == "ready", service.error
    calls = []
    original = service.backend._generate

    def spy(audio, language, max_tokens):
        calls.append((len(audio) / 16000, language, max_tokens))
        return original(audio, language, max_tokens)

    service.backend._generate = spy
    audio = (np.random.default_rng(0).standard_normal(16000 * 70) * 0.05).astype(np.float32)
    assert isinstance(service.transcribe_audio(audio, "ar"), str)
    assert len(calls) == 3
    assert all(seconds <= 30.0 and max_tokens == 256 for seconds, _, max_tokens in calls)
    service.unload()
    assert service.status == "off" and service.backend is None


def test_auto_language_lets_the_model_detect_it(checkpoint):
    path, _ = checkpoint
    backend = Qwen3MLXBackend(path)
    seen = []
    original = backend._model.generate

    def spy(audio, **kwargs):
        seen.append(kwargs["language"])
        return original(audio, **kwargs)

    backend._model.generate = spy
    audio = (np.random.default_rng(1).standard_normal(16000 * 2) * 0.05).astype(np.float32)
    for code in ("ar", "en", "auto"):
        assert isinstance(backend.transcribe(audio, code), str)
    assert seen == ["Arabic", "English", None]


def test_qwen3_base_model_keeps_its_tied_head(qwen3_checkpoint):
    assert not (qwen3_checkpoint / "tokenizer.json").exists()
    backend = Qwen3MLXBackend(qwen3_checkpoint)
    inner = backend._model._model
    assert getattr(inner, "lm_head", None) is None  # the embeddings are the head
    tokenizer = inner._tokenizer
    assert tokenizer.convert_tokens_to_ids("<asr_text>") is not None
    assert tokenizer.convert_tokens_to_ids("<|im_end|>") == tokenizer.eos_token_id


def test_qwen3_languages_reach_the_model_by_name(qwen3_checkpoint):
    from navo_engine.engines import PROFILES

    profile = PROFILES["qwen3"]
    service = ASRService(str(qwen3_checkpoint), engine_id="qwen3", name=profile.name, family=profile.family,
                         languages=profile.languages)
    service.load()
    assert service.status == "ready", service.error
    seen = []
    original = service.backend._model.generate

    def spy(audio, **kwargs):
        seen.append(kwargs["language"])
        return original(audio, **kwargs)

    service.backend._model.generate = spy
    audio = (np.random.default_rng(2).standard_normal(16000 * 2) * 0.05).astype(np.float32)
    for code in ("fr", "yue", "fil", "auto"):
        assert isinstance(service.transcribe_audio(audio, code), str)
    assert seen == ["French", "Cantonese", "Filipino", None]
    with pytest.raises(ValueError):
        service.transcribe_audio(audio, "sw")  # Whisper knows Swahili, Qwen3-ASR does not
