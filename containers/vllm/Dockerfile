FROM vllm/vllm-openai:v0.20.2-cu129-ubuntu2404

ARG HF_TOKEN=""

RUN HF_TOKEN="$HF_TOKEN" hf download \
      google/gemma-4-E2B-it \
      --local-dir /models/gemma-4-E2B-it

ENV INTERNAL_API_KEY=default

EXPOSE 8000

# The base image sets ENTRYPOINT ["vllm","serve"]. Reset it so our shell-form CMD
# below runs directly (otherwise CMD gets appended as args to "vllm serve" and the
# shell's -c flag collides with vLLM's --compilation-config/-cc, crashing startup).
ENTRYPOINT []

CMD exec vllm serve /models/gemma-4-E2B-it \
    --served-model-name google/gemma-4-E2B-it \
    --dtype bfloat16 \
    --max-model-len 32768 \
    --gpu-memory-utilization 0.85 \
    --limit-mm-per-prompt '{"image": 0, "audio": 0}' \
    --api-key "${INTERNAL_API_KEY}" \
    --host 0.0.0.0 \
    --port 8000
