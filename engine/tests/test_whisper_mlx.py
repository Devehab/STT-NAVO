"""Whisper Large v3 Turbo on MLX with a tiny random checkpoint laid out like the real one.

The vocabulary and special tokens match Whisper Large v3 (51,866 ids, 100 languages), so
mlx-audio treats it as the multilingual model; only the layers are tiny. Runs where MLX and
mlx-audio are installed (the Navo engine venv, or Linux with mlx[cpu]).

    cd engine && python -m pytest -q tests/test_whisper_mlx.py
"""

import json
import sys
from pathlib import Path

import numpy as np
import pytest

mx = pytest.importorskip("mlx.core")
pytest.importorskip("mlx_audio.stt.models.whisper")
pytest.importorskip("tokenizers")

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from navo_engine.asr import ASRService, WhisperMLXBackend  # noqa: E402
from navo_engine.engines import PROFILES  # noqa: E402

TEXT_TOKENS = 50257  # ids below this are text, as in Whisper's vocabulary
SECONDS = 16000


@pytest.fixture(scope="module")
def checkpoint(tmp_path_factory):
    from mlx.utils import tree_flatten
    from mlx_audio.stt.models.whisper.tokenizer import LANGUAGES
    from mlx_audio.stt.models.whisper.whisper import Model, ModelDimensions
    from tokenizers import AddedToken, Tokenizer, decoders, models, pre_tokenizers

    out = tmp_path_factory.mktemp("tiny-whisper")
    alphabet = pre_tokenizers.ByteLevel.alphabet()
    vocab = {symbol: index for index, symbol in enumerate(sorted(alphabet))}
    while len(vocab) < TEXT_TOKENS:
        vocab[f"w{len(vocab)}"] = len(vocab)
    tok = Tokenizer(models.BPE(vocab=vocab, merges=[]))
    tok.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    tok.decoder = decoders.ByteLevel()
    special = ["<|endoftext|>", "<|startoftranscript|>"]
    special += [f"<|{code}|>" for code in LANGUAGES]
    special += ["<|translate|>", "<|transcribe|>", "<|startoflm|>", "<|startofprev|>", "<|nospeech|>", "<|notimestamps|>"]
    special += [f"<|{i * 0.02:.2f}|>" for i in range(1501)]
    tok.add_special_tokens([AddedToken(t, special=True, normalized=False) for t in special])
    assert tok.get_vocab_size() == 51866 and tok.token_to_id("<|0.00|>") == 50365
    tok.save(str(out / "tokenizer.json"))
    (out / "tokenizer_config.json").write_text(json.dumps({
        "tokenizer_class": "WhisperTokenizer", "processor_class": "WhisperProcessor",
        "bos_token": "<|endoftext|>", "eos_token": "<|endoftext|>", "unk_token": "<|endoftext|>",
        "pad_token": "<|endoftext|>", "model_max_length": 448}))
    (out / "preprocessor_config.json").write_text(json.dumps({
        "feature_extractor_type": "WhisperFeatureExtractor", "feature_size": 128, "hop_length": 160, "n_fft": 400,
        "chunk_length": 30, "n_samples": 480000, "nb_max_frames": 3000, "padding_side": "right",
        "padding_value": 0.0, "return_attention_mask": False, "sampling_rate": 16000,
        "processor_class": "WhisperProcessor"}))
    config = {
        "model_type": "whisper", "num_mel_bins": 128, "max_source_positions": 1500, "d_model": 32,
        "encoder_attention_heads": 2, "encoder_layers": 1, "vocab_size": 51866, "max_target_positions": 64,
        "decoder_attention_heads": 2, "decoder_layers": 1,
    }
    (out / "config.json").write_text(json.dumps(config))
    model = Model(ModelDimensions.from_dict(config))
    weights = {key: value.astype(mx.float16) for key, value in tree_flatten(model.parameters())}
    mx.save_safetensors(str(out / "model.safetensors"), weights)
    return out


def test_loads_as_the_multilingual_model(checkpoint):
    backend = WhisperMLXBackend(checkpoint)
    assert backend._model.is_multilingual and backend._model.num_languages == 100
    tokenizer = backend._model.get_tokenizer(language="ar")
    assert tokenizer.sot_sequence == (50258, tokenizer.language_token, 50360)


def test_languages_reach_the_model_as_codes(checkpoint):
    backend = WhisperMLXBackend(checkpoint)
    seen = []
    original = backend._model.generate

    def spy(audio, **kwargs):
        seen.append((kwargs["language"], kwargs["return_timestamps"], kwargs["condition_on_previous_text"]))
        return original(audio, **kwargs)

    backend._model.generate = spy
    audio = (np.random.default_rng(1).standard_normal(SECONDS * 2) * 0.05).astype(np.float32)
    for code in ("ar", "en", "fr", "auto"):
        assert isinstance(backend.transcribe(audio, code), str)
    assert seen == [("ar", False, False), ("en", False, False), ("fr", False, False), (None, False, False)]


def test_long_audio_is_cut_into_windows(checkpoint):
    profile = PROFILES["whisper"]
    service = ASRService(str(checkpoint), engine_id="whisper", name=profile.name, family=profile.family,
                         languages=profile.languages)
    service.load()
    assert service.status == "ready", service.error
    assert service.backend_name == "mlx"
    lengths = []
    original = service.backend._generate

    def spy(audio, language, temperature=WhisperMLXBackend.TEMPERATURES):
        lengths.append(len(audio) / SECONDS)
        return original(audio, language, temperature)

    service.backend._generate = spy
    audio = (np.random.default_rng(0).standard_normal(SECONDS * 70) * 0.05).astype(np.float32)
    assert isinstance(service.transcribe_audio(audio, "en"), str)
    assert len(lengths) == 3 and all(seconds <= 30.0 for seconds in lengths)
    with pytest.raises(ValueError):
        service.transcribe_audio(audio[:SECONDS], "fil")  # Qwen3's code; Whisper calls it "tl"
    service.unload()
    assert service.status == "off" and service.backend is None
