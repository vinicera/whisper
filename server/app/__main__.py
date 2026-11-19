"""`python -m app` sobe o servidor com as configuracoes do .env."""
import logging
import os

import uvicorn

from .main import create_app


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    uvicorn.run(
        create_app(),
        host=os.getenv("HOST", "0.0.0.0"),
        port=int(os.getenv("PORT", "8787")),
        # Para HTTPS direto (sem Tailscale Serve), aponte para o cert gerado:
        ssl_certfile=os.getenv("SSL_CERTFILE") or None,
        ssl_keyfile=os.getenv("SSL_KEYFILE") or None,
    )


if __name__ == "__main__":  # protege o spawn do multiprocessing no Windows
    main()
