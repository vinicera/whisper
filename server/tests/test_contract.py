from app.export_schema import CONTRACT_DIR, SCHEMAS, render


def test_schemas_up_to_date():
    for name, model in SCHEMAS.items():
        path = CONTRACT_DIR / name
        assert path.exists(), f"rode: python -m app.export_schema ({name} ausente)"
        assert path.read_text(encoding="utf-8") == render(model), (
            f"{name} desatualizado: rode  python -m app.export_schema  na pasta server/"
        )
