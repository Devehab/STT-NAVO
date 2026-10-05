"""Gemma 4 and Llama 3.1 on MLX with tiny random checkpoints laid out like the real ones.

The layers are tiny, but the files, the configuration names and the chat templates follow the
real repositories, so loading and writing go through mlx-lm exactly as they do on a Mac.
Runs where MLX and mlx-lm are installed (the Navo engine venv, or Linux with mlx[cpu]).

    cd engine && python -m pytest -q tests/test_llm_mlx.py
"""

import json
import sys
from pathlib import Path

import pytest

mx = pytest.importorskip("mlx.core")
pytest.importorskip("mlx_lm")
pytest.importorskip("tokenizers")

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from navo_engine.llms import LLM_PROFILES, LanguageModel, PromptTooLong  # noqa: E402

LLAMA_TEMPLATE = (
    "{{- bos_token }}"
    "{%- if not date_string is defined %}{%- set date_string = '26 Jul 2024' %}{%- endif %}"
    "{%- if messages[0]['role'] == 'system' %}{%- set system_message = messages[0]['content'] %}"
    "{%- set messages = messages[1:] %}{%- else %}{%- set system_message = '' %}{%- endif %}"
    "{{- '<|start_header_id|>system<|end_header_id|>\\n\\n' }}"
    "{{- 'Today Date: ' + date_string + '\\n\\n' + system_message + '<|eot_id|>' }}"
    "{%- for message in messages %}"
    "{{- '<|start_header_id|>' + message['role'] + '<|end_header_id|>\\n\\n' + message['content'] + '<|eot_id|>' }}"
    "{%- endfor %}"
    "{%- if add_generation_prompt %}{{- '<|start_header_id|>assistant<|end_header_id|>\\n\\n' }}{%- endif %}"
)

GEMMA_TEMPLATE = (
    "{{- bos_token }}"
    "{%- for message in messages %}"
    "{%- set role = 'model' if message['role'] == 'assistant' else message['role'] %}"
    "{{- '<|turn>' + role + '\\n' + message['content'] + '<turn|>\\n' }}"
    "{%- endfor %}"
    "{%- if add_generation_prompt %}{{- '<|turn>model\\n' }}{%- endif %}"
)


def write_tokenizer(out, special, bos, eos, template):
    from tokenizers import Tokenizer, decoders, models, pre_tokenizers, trainers

    tok = Tokenizer(models.BPE())
    tok.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    tok.decoder = decoders.ByteLevel()
    trainer = trainers.BpeTrainer(vocab_size=400, special_tokens=special, initial_alphabet=pre_tokenizers.ByteLevel.alphabet())
    tok.train_from_iterator(["Summarize the meeting in three points. مرحبا hello system user assistant model"] * 20, trainer)
    tok.save(str(out / "tokenizer.json"))
    (out / "tokenizer_config.json").write_text(json.dumps({
        "tokenizer_class": "PreTrainedTokenizerFast", "bos_token": bos, "eos_token": eos, "chat_template": template,
    }))
    return tok


def save_weights(out, model):
    from mlx.utils import tree_flatten

    mx.save_safetensors(str(out / "model.safetensors"), dict(tree_flatten(model.parameters())))


@pytest.fixture(scope="module")
def llama_folder(tmp_path_factory):
    from mlx_lm.models import llama

    out = tmp_path_factory.mktemp("tiny-llama")
    special = ["<|begin_of_text|>", "<|eot_id|>", "<|start_header_id|>", "<|end_header_id|>"]
    tok = write_tokenizer(out, special, "<|begin_of_text|>", "<|eot_id|>", LLAMA_TEMPLATE)
    config = {
        "model_type": "llama", "hidden_size": 32, "num_hidden_layers": 2, "intermediate_size": 64,
        "num_attention_heads": 4, "num_key_value_heads": 2, "rms_norm_eps": 1e-5, "vocab_size": tok.get_vocab_size(),
        "bos_token_id": tok.token_to_id("<|begin_of_text|>"), "eos_token_id": tok.token_to_id("<|eot_id|>"),
        "tie_word_embeddings": False,
    }
    (out / "config.json").write_text(json.dumps(config))
    save_weights(out, llama.Model(llama.ModelArgs.from_dict(config)))
    return out


@pytest.fixture(scope="module")
def gemma_folder(tmp_path_factory):
    from mlx_lm.models import gemma4

    out = tmp_path_factory.mktemp("tiny-gemma")
    tok = write_tokenizer(out, ["<pad>", "<eos>", "<bos>", "<|turn>", "<turn|>"], "<bos>", "<eos>", GEMMA_TEMPLATE)
    vocab = tok.get_vocab_size()
    config = {
        "model_type": "gemma4",
        "vocab_size": vocab,
        "eos_token_id": [tok.token_to_id("<eos>"), tok.token_to_id("<turn|>")],
        "text_config": {
            "model_type": "gemma4_text", "hidden_size": 32, "num_hidden_layers": 10, "intermediate_size": 64,
            "num_attention_heads": 2, "num_key_value_heads": 1, "head_dim": 16, "global_head_dim": 16,
            "num_kv_shared_layers": 5, "hidden_size_per_layer_input": 8, "vocab_size": vocab,
            "vocab_size_per_layer_input": vocab, "sliding_window": 16, "use_double_wide_mlp": False,
            "tie_word_embeddings": True,
        },
        # The real repository also describes the towers mlx-lm leaves out for text.
        "vision_config": {"hidden_size": 8}, "audio_config": {"hidden_size": 8},
    }
    (out / "config.json").write_text(json.dumps(config))
    save_weights(out, gemma4.Model(gemma4.ModelArgs.from_dict(config)))
    return out


MESSAGES = [
    {"role": "system", "content": "Summarize the meeting in three points."},
    {"role": "user", "content": "مرحبا hello"},
]


@pytest.mark.parametrize("llm_id", ["llama", "gemma"])
def test_loads_and_writes_through_mlx_lm(llm_id, llama_folder, gemma_folder):
    folder = llama_folder if llm_id == "llama" else gemma_folder
    model = LanguageModel(LLM_PROFILES[llm_id], str(folder), context_tokens=1024)
    assert model.info()["downloaded"] is True and model.status == "asleep"
    model.load()
    assert model.status == "ready", model.error
    heard = []
    done = model.generate(MESSAGES, temperature=0.0, max_tokens=12, on_text=heard.append)
    assert isinstance(done.text, str) and "".join(heard).strip() == done.text
    assert done.prompt_tokens > 10 and 1 <= done.completion_tokens <= 12
    assert done.finish_reason in ("stop", "length")
    # Sampling options and a repetition penalty are accepted too.
    done = model.generate(MESSAGES, temperature=0.7, top_p=0.9, top_k=40, repetition_penalty=1.1, max_tokens=5)
    assert done.completion_tokens <= 5
    with pytest.raises(PromptTooLong):
        model.generate([{"role": "user", "content": "hello " * 2000}])
    model.unload()
    assert model.status == "asleep" and not model.loaded


def test_the_chat_template_gets_the_system_prompt_and_today(llama_folder, gemma_folder):
    from datetime import date

    llama = LanguageModel(LLM_PROFILES["llama"], str(llama_folder))
    llama.load()
    ids = llama.prompt_ids(MESSAGES)
    text = llama._tokenizer.decode(ids)
    assert text.count("<|begin_of_text|>") == 1  # the template's own, not a second one
    assert "Summarize the meeting in three points." in text and "مرحبا hello" in text
    assert date.today().strftime("%d %b %Y") in text and "26 Jul 2024" not in text
    assert text.endswith("<|start_header_id|>assistant<|end_header_id|>\n\n")

    gemma = LanguageModel(LLM_PROFILES["gemma"], str(gemma_folder))
    gemma.load()
    text = gemma._tokenizer.decode(gemma.prompt_ids([*MESSAGES, {"role": "developer", "content": "x"}]))
    assert text.startswith("<bos><|turn>system\n") and text.endswith("<|turn>model\n")
    assert "<|turn>system\nx<turn|>" in text  # "developer" is OpenAI's newer word for system
