# Passo a passo de instalação keepalived (manual)

## Verificação dos scripts

| Arquivo | Status |
|---------|--------|
| [`ka-status.sh`](ka-status.sh) | OK — checa VIP; no MASTER exige `fs_cli` + profiles `RUNNING`; no BACKUP exit 0 |
| [`ka-notify.sh`](ka-notify.sh) | OK — MASTER sobe FS + `sofia recover`; BACKUP/FAULT/STOP para FS |
| [`sudoers.keepalived-freeswitch`](sudoers.keepalived-freeswitch) | OK — NOPASSWD para www-data start/stop freeswitch |
| [`keepalived.conf.*.example`](keepalived.conf.pri.example) | OK — referência; o install só altera paths `.pl` → `.sh` no conf atual |
| [`install-on-node.sh`](install-on-node.sh) | Backup completo em `/root/keepalived-backup-YYYYMMDD-HHMMSS/` antes de instalar |

## Ordem recomendada

1. Instalar no **SEC** (BACKUP) primeiro — se o reload parar o FreeSWITCH lá, o PRI continua no ar.
2. Validar backup + conf no SEC.
3. Instalar no **PRI** (MASTER).
4. Só então `reload` no PRI (com cuidado).

## Em cada nó (como root)

### 1. Copiar artefatos para `/tmp`

Na sua máquina local:

```bash
cd ~/dev/fusionpbx-keepalived-ha

# Via jump host, chave id_rsa no hop e no destino:
scp -i ~/.ssh/id_rsa \
  -o "ProxyCommand=ssh -i ~/.ssh/id_rsa -W %h:%p admin@jumphost.example.com" \
  install-on-node.sh ka-status.sh ka-notify.sh sudoers.keepalived-freeswitch \
  admin@pbx-sec.example.com:/tmp/

scp -i ~/.ssh/id_rsa \
  -o "ProxyCommand=ssh -i ~/.ssh/id_rsa -W %h:%p admin@jumphost.example.com" \
  install-on-node.sh ka-status.sh ka-notify.sh sudoers.keepalived-freeswitch \
  admin@pbx-pri.example.com:/tmp/
```

Ou, já logado no jump host, `scp -i id_rsa` / `rsync -e "ssh -i id_rsa"` equivalente para `/tmp` em cada nó.

### 2. Rodar o instalador (ainda sem reload)

No **SEC**, como root:

```bash
bash /tmp/install-on-node.sh
```

Conferir saída:

- `BACKUP_DIR=/root/keepalived-backup-...`
- `ls` do backup com `keepalived/`, `MANIFEST.txt`, status, `ip-addr.txt`, `sofia-xmlstatus.xml`
- `grep ka- /etc/keepalived/keepalived.conf` apontando para `.sh`
- `ka-status exit: 0`
- `.pl` ainda presentes em `/etc/keepalived/` (não apagados)

Repetir no **PRI**.

### 3. Ativar (reload) — um nó por vez

No **SEC** (BACKUP):

```bash
systemctl reload keepalived
# Esperado: notify BACKUP → FreeSWITCH PARA neste nó
systemctl is-active freeswitch keepalived
ip -br a
journalctl -t ka-notify -t ka-status -n 30 --no-pager
```

No **PRI** (MASTER), só depois do SEC ok:

```bash
systemctl reload keepalived
# Esperado: VIPs permanecem; FreeSWITCH continua ativo
systemctl is-active freeswitch keepalived
ip -br a | grep -E '190|50'
sudo -u www-data /etc/keepalived/ka-status.sh; echo exit:$?
fs_cli -x "sofia status" | head -20
journalctl -t ka-notify -t ka-status -n 30 --no-pager
```

## Rollback (se precisar)

```bash
BACKUP=/root/keepalived-backup-TIMESTAMP   # usar o path impresso no install
cp -a "$BACKUP/keepalived/"* /etc/keepalived/
rm -f /etc/sudoers.d/keepalived-freeswitch   # se não havia antes
systemctl reload keepalived
# Se o FS foi parado no SEC e quiser restaurar o modo antigo (FS nos dois):
# systemctl start freeswitch
```

## Avisos

- Reload no BACKUP **para o FreeSWITCH** (ativo/passivo).
- `fall 18` × `interval 5` ≈ 90s antes do failover por profile down.
- Profiles monitorados: `fs_profile_internal`, `fs_profile_external`.
- Não fechar as sessões SSH root durante a operação.
- FreeSWITCH: preferível `disabled` no boot nos dois nós; o notify do keepalived sobe/desce o serviço.
- **`nopreempt` é obrigatório** em cada `vrrp_instance`. Sem isso, após FAULT o PRI (prio 255) reassumem a VIP em segundos porque `ka-status` retorna OK sem VIP — o backup sobe o FS e é derrubado de novo.
- **`state` deve ser `BACKUP` em TODOS os nós** (incluindo o PRI com priority 255). Com `state MASTER`, o keepalived **ignora** `nopreempt` (`Warning - nopreempt will not work with initial state MASTER`).
- Com `nopreempt` + `state BACKUP`, o failback para o PRI só ocorre se o MASTER atual (SEC) falhar ou o keepalived do SEC for parado/reiniciado.
- Ao virar MASTER, `ka-notify` grava grace de **90s** (`/tmp/ka-fs-grace-until`). Nesse período `ka-status` não falha se `fs_cli`/profiles ainda não estão prontos — necessário com `fall` baixo (ex.: 2), senão o SEC cai em FAULT no meio do `systemctl start freeswitch`.
- Recomendado: `fall` >= 6 (30s) mesmo com grace; `fall 2` só é seguro com o grace stamp ativo.
