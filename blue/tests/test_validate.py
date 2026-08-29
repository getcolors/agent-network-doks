"""The port of green's validate-test."""

from package_agent_network_doks_blue import validate


def test_fixture_is_valid(fixture):
    assert validate.state_errors(fixture) == []


def test_required_keys_are_enforced(fixture):
    for k in validate.required:
        opts = {key: v for key, v in fixture.items() if key != k}
        errors = validate.state_errors(opts)
        assert any(f":{k}" in e for e in errors), f"{k} missing must be reported"


def test_env_guard():
    assert validate.env_errors({}) == []
    assert validate.env_errors({"COLORS_PAR_PROFILE": "other"})


def test_image_pins(fixture):
    # A floating tag is refused.
    for bad in ("netbirdio/netbird:latest", "netbirdio/netbird:main",
                "netbirdio/netbird:latest@sha256:66f408b0c423e9c3376deea7bc0da78024d32494dd0f957344993015b74c4451"):
        assert validate.state_errors({**fixture, "agent-network-client-image": bad}), bad
    # A bare repository means :latest by implication and is refused.
    assert validate.state_errors({**fixture, "agent-network-client-image": "netbirdio/netbird"})


def test_model_shape(fixture):
    # The allowlist must be claimed.
    assert validate.model_errors({**fixture, "agent-network-allowed-models": ["not-claimed"]})
    # At least one claimed model must sit outside the allowlist.
    assert validate.model_errors({
        **fixture,
        "agent-network-allowed-models": ["claude-haiku-4-5-20251001", "claude-sonnet-4-5-20250929"],
    })
    # The denial probe's negative case is derivable.
    assert validate.denied_claimed_model(fixture) == "claude-sonnet-4-5-20250929"
    assert validate.allowed_model(fixture) == "claude-haiku-4-5-20251001"


def test_budget_ceilings(fixture):
    assert validate.state_errors({**fixture, "agent-network-policy-budget-usd-per-day": 50})
    assert validate.state_errors({**fixture, "agent-network-policy-tokens-per-day": 99999999})


def test_doks_version_shape(fixture):
    assert validate.state_errors({**fixture, "doks-version": "1.34.1-do.0"}) == []
    for bad in ("v1.35.2+1", "1.36.3", "1.36.3.do-2", "latest"):
        assert validate.state_errors({**fixture, "doks-version": bad}), bad


def test_registry_modes(fixture):
    # Create mode requires the tier.
    no_tier = {k: v for k, v in fixture.items() if k != "digitalocean-registry-tier"}
    assert validate.state_errors(no_tier)
    assert validate.state_errors({**fixture, "digitalocean-registry-tier": "gold"})
    # Adopt mode rejects the tier and validates the name.
    adopt = {**{k: v for k, v in fixture.items() if k != "digitalocean-registry-tier"},
             "digitalocean-registry-name": "existing-registry"}
    assert validate.state_errors(adopt) == []
    assert validate.adopt_registry(adopt)
    assert validate.registry_name(adopt) == "existing-registry"
    assert validate.state_errors({**adopt, "digitalocean-registry-tier": "basic"})
    assert validate.state_errors({**adopt, "digitalocean-registry-name": "Bad_Name"})
    # The owned repository is always the profile.
    assert validate.registry_repository(fixture) == "agent-network-doks-fixture"


def test_naming(fixture):
    # The compute name defaults to the profile (Compute Name Standard).
    assert validate.compute_name(fixture) == "agent-network-doks-fixture"
    assert validate.compute_name({**fixture, "digitalocean-name": "custom"}) == "custom"
    assert validate.compute_name({**fixture, "digitalocean-name": "REPLACE_ME"}) \
        == "agent-network-doks-fixture"
    # The registry name is the compute name reduced to what DOCR accepts.
    assert validate.registry_name(fixture) == "agent-network-doks-fixture"
    assert validate.registry_name({"profile": "Mixed_Case!"}) == "mixedcase"


def test_zone_derivation(fixture):
    assert validate.zone(fixture) == "example.com"


def test_secret_requirements(fixture):
    # Create needs the providers, the backend and the Anthropic key.
    errors = validate.secret_errors({**fixture, "provider-backend": "r2"}, "create")
    for v in ("COLORS_PAR_DO_TOKEN", "COLORS_PAR_CLOUDFLARE_API_TOKEN",
              "COLORS_PAR_ANTHROPIC_API_KEY", "COLORS_PAR_R2_ACCESS_KEY_ID"):
        assert any(v in e for e in errors), v
    # Delete never demands the Anthropic key.
    errors = validate.secret_errors(fixture, "delete")
    assert not any("ANTHROPIC" in e for e in errors)


def test_gost_pin_shape(fixture):
    assert validate.state_errors({**fixture, "agent-network-gost-sha256": "abc"})
    assert validate.state_errors({**fixture, "agent-network-gost-version": "3.2"})


def test_http_sources_are_real_cidrs(fixture):
    assert validate.state_errors({**fixture, "digitalocean-http-sources": ["10.0.0.0/8", "0.0.0.0/0"]}) == []
    for bad in (["999.999.999.999/99"], ["1.2.3.4/33"], ["1.2.3.256/8"], ["::/0"], ["1.2.3.4"]):
        assert validate.state_errors({**fixture, "digitalocean-http-sources": bad}), repr(bad)
