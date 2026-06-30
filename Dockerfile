FROM caddy:2-alpine

COPY . /srv
COPY Caddyfile /etc/caddy/Caddyfile