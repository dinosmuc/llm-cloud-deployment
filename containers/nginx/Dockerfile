# nginx sidecar — authenticating reverse proxy for the vLLM container.
#
# Two API keys live in this container:
#   API_KEY       — user-facing token nginx validates on the inbound x-api-key header
#   VLLM_API_KEY  — internal token nginx injects as Authorization: Bearer upstream,
#                   matching vLLM's --api-key check
#
# Both are supplied by the ECS task definition and substituted into
# /etc/nginx/nginx.conf by envsubst at container start. They are listed
# explicitly so envsubst leaves nginx's own $variables (e.g. $host) untouched.

FROM nginx:alpine

COPY nginx.conf /etc/nginx/templates/nginx.conf.template

ENV API_KEY=default
ENV VLLM_API_KEY=default

CMD ["/bin/sh", "-c", "envsubst '$API_KEY $VLLM_API_KEY' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf && nginx -g 'daemon off;'"]
