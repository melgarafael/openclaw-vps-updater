# OpenClaw VPS Updater

Atualiza o OpenClaw (rodando via Docker) na sua VPS com **um comando**. Feito para
VPS tipo HostGator, mas funciona em qualquer VPS onde o OpenClaw roda em container:
o script **descobre sozinho** o container, o diretório do compose, a porta e os
volumes. Não assume caminho nenhum.

## Uso

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/melgarafael/openclaw-vps-updater/main/update-openclaw.sh)
```

Versão específica ou só simular:

```bash
sudo ./update-openclaw.sh 1.2.3     # atualiza para uma versão exata
sudo ./update-openclaw.sh --dry-run # mostra o que faria, sem mudar nada
```

## O que ele faz (autônomo)

1. **Descobre** container, diretório do compose, serviço, porta e volumes.
2. Acha a **última versão** publicada (`npm view openclaw version`) e confirma que a
   imagem existe no registry antes de mexer em algo.
3. Checa **disco** e libera com prune seguro (build cache + imagens órfãs) se faltar.
4. Faz **backup** do diretório do compose.
5. Troca os **tags de versão** no `Dockerfile` e no `docker-compose.yml`.
6. **Builda** a nova imagem (o container atual segue no ar) e **recria** o container.
7. Corrige a **pegadinha do healthcheck** (imagem nova aponta pra porta padrão; se seu
   deploy usa porta custom, o container ficaria "unhealthy" à toa) via override aditivo.
8. **Trata a travessia 6.x→7.x** (ver abaixo) se o gateway travar na migração de state dir.
9. **Verifica** o `/healthz` (com timeout — o gateway leva ~30s pra ficar ready), remove
   a imagem antiga e entrega um resumo.

## A travessia 6.x → 7.x (breaking change)

A 7.x renomeou o diretório de estado de `.clawdbot` para `.openclaw` e passou a **exigir**
a migração no boot. Como a própria imagem já traz um `.openclaw` esqueleto, a migração
trava com *"State dir migration skipped: target already exists"* e o gateway se recusa a
subir. O script detecta isso nos logs e aplica o remédio automaticamente:

- aponta `OPENCLAW_STATE_DIR` para o volume de config que já persiste (`XDG_CONFIG_HOME`),
  para a config nova não cair em storage efêmero;
- roda `openclaw doctor --fix` no boot, que gera a config no formato novo (`openclaw.json`)
  a partir da sua config antiga — preservando modelo, token e canais;
- recria com `--force-recreate` (camada limpa) e revalida.

Se o gateway não ficar saudável nem após o remédio, faz **rollback** para a versão anterior.

## Por que é seguro

- **Config, token e modelo vivem em volumes nomeados** — nunca são tocados.
- **Rollback automático**: qualquer falha reverte o compose do backup e sobe a versão
  anterior. A imagem antiga só é removida no fim, depois do novo container passar no
  healthcheck — então nunca ficamos sem uma imagem pra voltar.
- **Nada irreversível sem saída**: falta de disco é resolvida só com prune seguro; se
  não der, o script **para** em vez de apagar a imagem em uso.

## Requisitos

- Ser `root` (ou `sudo`), Docker, e `docker compose` (v2) ou `docker-compose` (v1).
- Uma instalação OpenClaw feita via `docker compose` (não um `docker run` cru).

## Rollback manual

Se precisar voltar à mão, o backup fica em `<dir-do-compose>.bak-<data>`:

```bash
cp -a <dir-do-compose>.bak-<data>/. <dir-do-compose>/
cd <dir-do-compose> && docker compose up -d
```

Config e workspace não são tocados (volumes), então não há perda de dados.

---

Open source · MIT · feito para o canal [@melgarafael](https://youtube.com/@melgarafael).
