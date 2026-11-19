# Whisper: assistente auditivo de Cálculo para Ray-Ban Meta

O usuário fotografa a questão, toca nos óculos e ouve a resolução falada por extenso, sem símbolos.
App iOS leve (SwiftUI) + servidor ponte opcional no PC Windows (FastAPI + SymPy).

```
ios/          App SwiftUI (XcodeGen) + pacote Core (contrato + sanitizador, testável)
server/       FastAPI: visão (Gemini) -> verificação SymPy -> fala limpa
shared/       Contrato JSON Schema + casos de teste do sanitizador (usados pelos 2 lados)
.github/      CI: .ipa sem assinatura (macOS) e testes do servidor (Ubuntu)
```

## Status das fases
- [x] **Fase 0**: pipeline do CI gerando o `.ipa` e app mínimo de voz (TTS pt-BR + sanitizador)
- [x] **Fase 1**: servidor (`/v1/health`, `/v1/solve`, `/v1/history`), verificação SymPy com re-geração e testes
- [ ] Fase 2: app MVP em primeiro plano (câmera/última foto -> Ponte/Direto -> fala)
- [ ] Fase 3: gatilho físico em segundo plano (`MPRemoteCommandCenter` + loop silencioso)
- [ ] Fase 4: robustez (fallback, fila, streaming por segmentos)
- [ ] Fase 5: captura direta pelo SDK Meta Wearables (DAT)

## Servidor (Windows)
```powershell
powershell -ExecutionPolicy Bypass -File server\scripts\run_server.ps1   # 1ª vez cria venv e .env
# edite server\.env (GEMINI_API_KEY, BRIDGE_TOKEN) e rode de novo
```
Para testar sem gastar cota, use `LLM_PROVIDER=fake` no `.env`.

Testes: `cd server; .\.venv\Scripts\python -m pytest -q`.
Se mudar `app/models.py`, rode `python -m app.export_schema` (o teste de contrato acusa a divergência).

### Acesso pelo iPhone (Tailscale)
1. Instale o Tailscale no PC e no iPhone, com a mesma conta.
2. No PC: `tailscale serve --bg 8787`. Isso expõe `https://<nome-do-pc>.<tailnet>.ts.net` com certificado válido, o que evita exceções de ATS no iOS.
3. No app, configure essa URL + o `BRIDGE_TOKEN`.

## App iOS (sem Mac)
1. Faça push para `main` no GitHub. O workflow **iOS build** gera `Whisper-<n>.ipa` em *Actions → Artifacts*.
2. Instale com o **Sideloadly** (Apple ID gratuito: a assinatura vale 7 dias) ou com o **SideStore** (renova pelo Wi-Fi).
3. Com os óculos pareados, toque em **Falar**. A seção "Saída de áudio" deve mostrar os óculos (`BluetoothA2DPOutput`).

> Repositório **público** = minutos macOS ilimitados no Actions. Em repositório privado, são ~200 min macOS/mês (≈25 builds).
> Nunca versione chaves: elas ficam no `server/.env` (ignorado) e no Keychain do iPhone.

## Uso responsável
Pensado para estudo, listas de exercícios e adaptações de acessibilidade. Em avaliações, use somente com autorização da instituição.
