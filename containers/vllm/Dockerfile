# vLLM inference container for Gemma 4 E2B IT.
#
# Base image:
#   vllm/vllm-openai is pinned to a specific digest tag (NOT :latest, NOT :gemma4).
#   v0.20.2 was the first vLLM release with stable Gemma 4 support; cu129 + ubuntu2404
#   matches the L4 (Ada Lovelace, sm_89) inference instances we target.
#
# Model:
#   Gemma 4 E2B IT (instruction-tuned), Apache 2.0, ungated on the HF Hub.
#   Weights are baked into the image at build time so the running container does not
#   need internet access. HF_TOKEN is an optional build ARG — the model is ungated,
#   but passing a token avoids the anonymous-pull rate limits on busy CI hosts.
#
# Precision:
#   bfloat16. The target instance is g6.xlarge (NVIDIA L4) which has native BF16
#   tensor cores. BF16 is NOT the right choice on T4 (g4dn.*); this image is
#   deliberately incompatible with that family.
#
# Modalities:
#   Text-only chatbot. Gemma 4 is natively multi-modal, but --limit-mm-per-prompt
#   pins images and audio to 0 so vLLM does not allocate the vision/audio encoders
#   or KV-cache budget for them. No tool-calling / reasoning parsers are enabled.
#
# Auth model (works with the nginx sidecar in containers/nginx/):
#   --api-key wires vLLM's built-in bearer-token check. The value comes from the
#   VLLM_API_KEY env var, which is set by the ECS task definition and is *internal*
#   — it never leaves the task. The user-facing key (x-api-key) is validated by
#   nginx, which then injects "Authorization: Bearer ${VLLM_API_KEY}" upstream.
#
# Image size:
#   Expect ~13-15 GB total (vLLM CUDA base ~7-8 GB + BF16 weights ~5 GB + Python deps).

FROM vllm/vllm-openai:v0.20.2-cu129-ubuntu2404

ARG HF_TOKEN=""

# `huggingface-cli download` was removed from huggingface_hub in early 2026;
# the replacement is `hf download`. HF_TOKEN is still read from the environment
# (the model is ungated but a token raises the anonymous rate limit).
RUN HF_TOKEN="$HF_TOKEN" hf download \
      google/gemma-4-E2B-it \
      --local-dir /models/gemma-4-E2B-it

ENV MODEL_ID=/models/gemma-4-E2B-it
ENV VLLM_API_KEY=default

EXPOSE 8000

# Shell form so ${VLLM_API_KEY} is substituted at container start.
# `exec` replaces the shell so vLLM becomes PID 1 and receives signals directly.
CMD exec vllm serve /models/gemma-4-E2B-it \
    --dtype bfloat16 \
    --max-model-len 32768 \
    --gpu-memory-utilization 0.85 \
    --limit-mm-per-prompt '{"image": 0, "audio": 0}' \
    --api-key "${VLLM_API_KEY}" \
    --host 0.0.0.0 \
    --port 8000
