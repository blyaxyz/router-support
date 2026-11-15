from deploy.update_telemt_config import BEGIN, END, update_config


def test_adds_managed_exclusive_mask_table() -> None:
    result = update_config("[censorship]\nmask = true\n", 8443, ["support.example.com"])
    assert "[censorship.exclusive_mask]" in result
    assert '"support.example.com" = "127.0.0.1:8443"' in result


def test_preserves_existing_routes_and_replaces_managed_block() -> None:
    source = f"""[censorship.exclusive_mask]
"existing.example" = "127.0.0.1:9443"
{BEGIN}
"old.example" = "127.0.0.1:8443"
{END}
"""
    result = update_config(source, 9444, ["new.example"])
    assert '"existing.example" = "127.0.0.1:9443"' in result
    assert "old.example" not in result
    assert '"new.example" = "127.0.0.1:9444"' in result
    assert result.count(BEGIN) == 1


def test_rejects_inline_exclusive_mask() -> None:
    source = "[censorship]\nexclusive_mask = { example = '127.0.0.1:443' }\n"
    try:
        update_config(source, 8443, ["support.example.com"])
    except ValueError as error:
        assert "inline" in str(error)
    else:
        raise AssertionError("inline map must be rejected")


def test_rejects_disabled_masking() -> None:
    try:
        update_config("[censorship]\nmask = false\n", 8443, ["support.example.com"])
    except ValueError as error:
        assert "mask" in str(error)
    else:
        raise AssertionError("disabled masking must be rejected")
