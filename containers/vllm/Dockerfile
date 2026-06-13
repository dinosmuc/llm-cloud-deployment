FROM vllm/vllm-openai:v0.20.2-cu129-ubuntu2404

ARG HF_TOKEN=""

RUN HF_TOKEN="$HF_TOKEN" hf download \
      google/gemma-4-E2B-it \
      --local-dir /models/gemma-4-E2B-it

ENV MODEL_ID=/models/gemma-4-E2B-it
ENV INTERNAL_API_KEY=default

EXPOSE 8000

CMD exec vllm serve /models/gemma-4-E2B-it \
    --dtype bfloat16 \
    --max-model-len 32768 \
    --gpu-memory-utilization 0.85 \
    --limit-mm-per-prompt '{"image": 0, "audio": 0}' \
    --api-key "${INTERNAL_API_KEY}" \
    --host 0.0.0.0 \
    --port 8000
