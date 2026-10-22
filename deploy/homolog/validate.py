"""Render Compose with fake credentials and assert isolation without starting services."""
import json
import os
from pathlib import Path
import subprocess

directory = Path(__file__).resolve().parent
env = dict(os.environ, POSTGRES_PASSWORD='ci-only', SECRET_KEY='ci-only',
           RABBITMQ_PASS='ci-only', RABBITMQ_ERLANG_COOKIE='ci-only',
           FRONTEND_IMAGE='ghcr.io/radybsb/taiga-hakoon-front:sha-' + '0' * 40,
           BACKEND_IMAGE='ghcr.io/radybsb/taiga-hakoon-back:sha-' + '0' * 40,
           POSTGRES_IMAGE='postgres:12.3', RABBITMQ_IMAGE='rabbitmq:3.8-management-alpine',
           EVENTS_IMAGE='taigaio/taiga-events:latest', PROTECTED_IMAGE='taigaio/taiga-protected:latest',
           GATEWAY_IMAGE='nginx:1.19-alpine', HOMOLOG_PORT='9002')
rendered = subprocess.check_output(['docker', 'compose', '--env-file', str(directory / '.env.example'),
                                  '-f', str(directory / 'compose.yml'), 'config', '--format', 'json'], env=env)
config = json.loads(rendered)
assert config['name'] == 'taiga-homolog'
assert len(config['services']) == 9
assert not any(v.get('external') for v in config['volumes'].values())
assert not any(v.get('external') for v in config['networks'].values())
for name, service in config['services'].items():
    assert service.get('mem_limit'), name
    assert 'build' not in service, name
    for volume in service.get('volumes', []):
        assert volume['type'] != 'bind' or volume['source'].endswith('gateway.conf'), volume
    assert service.get('networks') == {'taiga': None} or set(service.get('networks', {})) == {'taiga'}
    assert not service.get('ports') or name == 'taiga-gateway'
port = config['services']['taiga-gateway']['ports'][0]
assert port['host_ip'] == '127.0.0.1' and str(port['published']) == '9002'
api = config['services']['taiga-back']['environment']
assert api['POSTGRES_HOST'] == 'taiga-db' and api['POSTGRES_DB'] == 'taiga_homolog'
assert api['EMAIL_BACKEND'] == 'django.core.mail.backends.console.EmailBackend'
assert api['WEBHOOKS_ENABLED'] == 'False'
assert api['HAKOON_ENVIRONMENT'] == 'homolog'
assert api['SEED_TEST_USERS_ENABLED'] == 'False'
assert config['services']['taiga-back']['image'] == config['services']['taiga-async']['image']
print('PASS: nine services isolated from production; bounded memory, internal DB, console email, loopback gateway, matched backend/worker images')
