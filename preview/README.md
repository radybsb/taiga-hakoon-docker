# Front-end de teste no servidor de produção

Endereço escolhido: **https://taiga-homolog.hakoongames.com**.

Este é um front-end separado, com a API, usuários, permissões e dados da produção.
Usar apenas o projeto de teste acordado com a equipe. A API utilizada continua
sendo a oficial já instalada: esta implantação não adiciona endpoints ao backend.

```text
Navegador → HTTPS taiga-homolog.hakoongames.com
         → Nginx do host → 127.0.0.1:9002 → taiga-preview/frontend
                                           ├─ interface nova
                                           └─ /api, /media, /static, /events
                                              → taiga-gateway da produção
```

O Compose é independente e usa a rede externa `taiga-docker_taiga`, confirmada
no diagnóstico do servidor. Não define banco, volumes de dados, migrations,
workers ou serviços da produção. A porta 9002 fica restrita ao loopback.
Não combinar este arquivo com `docker-compose.yml` de produção.

## 1. Construir na máquina de desenvolvimento

No repositório `taiga-front`, confira `git status`: arquivos ainda não rastreados
em `app/` entram no contexto local do Docker, mas precisam estar commitados para
que outra pessoa reproduza o mesmo build por checkout. `node_modules`, builds
anteriores e `conf/conf.json` local são excluídos do contexto.

```sh
cd /home/rodrigo/Dev/Hakoon/Taiga/taiga-front

docker build --platform linux/amd64 \
  --build-arg VCS_REF="$(git rev-parse HEAD)" \
  -f docker/Dockerfile \
  -t hakoon/taiga-front:preview-20261015-01 .

docker save -o /tmp/taiga-front-preview-20261015-01.tar \
  hakoon/taiga-front:preview-20261015-01
```

Use uma tag nova a cada versão; não sobrescreva a imagem usada no teste anterior.
O builder usa Node 16 por compatibilidade com `node-sass` e as dependências legadas.
O container final contém Nginx e o conteúdo compilado; não executa Node ou Gulp.
A imagem base do runtime é `nginx:stable-alpine`; para builds reprodutíveis por
longos períodos, forneça `--build-arg NGINX_IMAGE=nginx@sha256:DIGEST` e registre
igualmente o digest de `NODE_IMAGE`. A tag própria identifica o artefato testado.

Os plugins opcionais Slack/GitHub/GitLab não são baixados automaticamente. Se
necessários, instalar suas distribuições em `/usr/share/nginx/html/plugins/`
antes de habilitá-los. O teste proposto deixa todos desabilitados.

## 2. Transferir a imagem e os arquivos de preview

Copie a imagem e a pasta `preview/` deste repositório para a VPS, por exemplo:

```sh
# Substitua VPS pelo endereço/IP real do servidor.
scp /tmp/taiga-front-preview-20261015-01.tar ubuntu@VPS:/tmp/
scp -r /home/rodrigo/Dev/Hakoon/Taiga/taiga-docker/preview \
  ubuntu@VPS:/opt/taiga/taiga-docker/
```

No servidor:

```sh
cd /opt/taiga/taiga-docker/preview
docker load -i /tmp/taiga-front-preview-20261015-01.tar
cp .env.example .env
# Conferir FRONTEND_IMAGE, a rede externa e o domínio de produção em .env.
docker network inspect taiga-docker_taiga
docker compose --env-file .env -f compose.yml config --quiet
docker compose --env-file .env -f compose.yml up -d --no-build
docker compose --env-file .env -f compose.yml ps
curl -f http://127.0.0.1:9002/healthz
curl -f http://127.0.0.1:9002/conf.json
```

O `conf.json` gerado usa `/api/v1/`, sem localhost no navegador. O Nginx do
container encaminha a chamada para `taiga-gateway`, com Host de produção.
Uploads de até 100 MB são aceitos pelos dois proxies, conforme o gateway atual.
O limite efetivo da API continua valendo. `/admin/` não é exposto pelo preview.

`ENABLE_EVENTS=false` corresponde ao diagnóstico em que o serviço de eventos
não estava em execução. Habilitar apenas se ele estiver disponível; o endereço
será `wss://taiga-homolog.hakoongames.com/events`.

## 3. Publicar HTTPS em um site novo do Nginx do host

Criar um registro DNS **A** para `taiga-homolog.hakoongames.com` apontando ao IP
da VPS. Só criar AAAA se o IPv6 estiver configurado. O site de produção continua
em seu arquivo atual e encaminhando a `127.0.0.1:9000`.

Instale **um site novo**, sem substituir arquivos existentes:

```sh
sudo install -m 644 nginx-host.conf.example \
  /etc/nginx/sites-available/taiga-homolog.hakoongames.com
sudo ln -s /etc/nginx/sites-available/taiga-homolog.hakoongames.com \
  /etc/nginx/sites-enabled/taiga-homolog.hakoongames.com
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d taiga-homolog.hakoongames.com --redirect
sudo nginx -t
```

A emissão exige DNS propagado e portas 80/443 acessíveis. O exemplo inicial
é HTTP para permitir a emissão; iniciar os testes autenticados somente após
confirmar o HTTPS. Certbot configura certificado e redirecionamento no site novo.
Não é preciso abrir a porta 9002 no firewall. Se mudar `PREVIEW_PORT` em `.env`,
ajuste também o `proxy_pass` do site novo.

A resposta adiciona `X-Robots-Tag: noindex, nofollow`. Isso não é controle de acesso:
os usuários acessam com as permissões normais do Taiga.

## 4. Validar

- Confirmar que o site de produção continua acessível e com a interface anterior.
- Conferir `/conf.json`, login e navegação no subdomínio de teste.
- No projeto de teste: seleção e ações em lote do backlog, incluindo status,
  tags, atribuição e mudança de sprint.
- Imagens e MP4 no editor: inserir, redimensionar, alinhar, agrupar, espaçar,
  inserir parágrafos antes/depois, salvar, recarregar e desfazer/refazer.
- Timeline: imagens sem link e MP4 com player.
- Conferir que scripts e estilos retornam seus tipos corretos e que arquivos
  inexistentes, como `/v-inexistente/js/app-loader.js`, retornam 404.

A API oficial deve ser compatível com as ações em lote utilizadas. Teste pelo
projeto dedicado antes de considerar a promoção da imagem.

URLs de anexos e links de notificações gerados pelo backend podem continuar
apontando para `taiga.hakoongames.com`: o backend mantém seu domínio de produção.
A autenticação no subdomínio de teste usa armazenamento local separado, então
pode ser necessário fazer login novamente. Não altera as credenciais existentes.

## 5. Atualizar ou encerrar

Para atualizar, carregar uma nova imagem, alterar somente `FRONTEND_IMAGE` em
`preview/.env` e executar `docker compose --env-file .env -f compose.yml up -d
--no-build`. Para voltar à interface anterior, restaurar a tag anterior e repetir
o comando. Não remover a imagem anterior antes de terminar a validação.

Para encerrar somente o teste:

```sh
cd /opt/taiga/taiga-docker/preview
docker compose --env-file .env -f compose.yml down
```

Depois, desabilitar apenas o site novo, validar com `nginx -t` e recarregar o
Nginx. A rede externa e os containers e volumes de produção permanecem intactos.
Não executar `down` no diretório de produção.

Esta configuração prepara o teste do front-end. Promover a imagem para o serviço
principal é uma etapa posterior, após a validação da equipe.
