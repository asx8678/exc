from types import MappingProxyType

from code_puppy import model_factory


def test_get_model_default_settings_returns_mutable_detached_copy():
    cached_config = MappingProxyType(
        {
            "default_settings": MappingProxyType(
                {
                    "extra_body": MappingProxyType({"provider_option": "default"}),
                    "metadata": MappingProxyType(
                        {"labels": [MappingProxyType({"name": "cached"})]}
                    ),
                }
            )
        }
    )

    settings = model_factory.get_model_default_settings(cached_config)

    assert settings == {
        "extra_body": {"provider_option": "default"},
        "metadata": {"labels": [{"name": "cached"}]},
    }

    settings["extra_body"]["provider_option"] = "changed"
    settings["metadata"]["labels"][0]["name"] = "changed"

    defaults = cached_config["default_settings"]
    assert defaults["extra_body"]["provider_option"] == "default"
    assert defaults["metadata"]["labels"][0]["name"] == "cached"


def test_get_model_default_settings_ignores_non_mapping(monkeypatch):
    warnings = []
    monkeypatch.setattr(model_factory, "emit_warning", warnings.append)

    assert model_factory.get_model_default_settings({"default_settings": ["bad"]}) == {}
    assert warnings == ["Model 'default_settings' must be a JSON object; ignoring it."]


def test_make_model_settings_applies_defaults_before_effective_settings(monkeypatch):
    cached_default_settings = MappingProxyType(
        {
            "temperature": 0.1,
            "top_p": 0.2,
            "extra_body": MappingProxyType({"provider_option": "default"}),
        }
    )
    model_config = MappingProxyType(
        {
            "context_length": 100_000,
            "max_output_tokens": 5_000,
            "default_settings": cached_default_settings,
        }
    )

    monkeypatch.setattr(
        model_factory.ModelFactory,
        "load_config",
        staticmethod(lambda: {"custom-model": model_config}),
    )
    monkeypatch.setattr(
        model_factory._config_module,
        "get_effective_model_settings",
        lambda model_name: {"temperature": 0.7},
    )
    monkeypatch.setattr(
        model_factory._config_module,
        "model_supports_setting",
        lambda model_name, setting: False,
    )
    monkeypatch.setattr(model_factory, "get_yolo_mode", lambda: True)

    settings = model_factory.make_model_settings("custom-model", max_tokens=4_000)

    assert settings["temperature"] == 0.7
    assert settings["top_p"] == 0.2
    assert settings["max_tokens"] == 4_000
    assert settings["extra_body"] == {"provider_option": "default"}

    settings["extra_body"]["provider_option"] = "changed"
    assert cached_default_settings["extra_body"]["provider_option"] == "default"
