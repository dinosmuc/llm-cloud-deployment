const API_URL = "${alb_url}";

// System prompt is injected by Terraform via templatefile() — see modules/frontend/main.tf.
// The string is declared in terraform/variables.tf and can be overridden per-environment
// from terraform.tfvars; the default establishes the chatbot persona.
const SYSTEM_PROMPT = "${system_prompt}";

let apiKey = "";
let isGenerating = false;

// DOM elements
const apiKeyInput = document.getElementById("apiKeyInput");
const connectBtn = document.getElementById("connectBtn");
const apiKeyBar = document.getElementById("apiKeyBar");
const status = document.getElementById("status");
const messages = document.getElementById("messages");
const userInput = document.getElementById("userInput");
const sendBtn = document.getElementById("sendBtn");

// Connect with API key
connectBtn.addEventListener("click", () => {
    const key = apiKeyInput.value.trim();
    if (!key) return;

    apiKey = key;
    apiKeyBar.classList.add("hidden");
    status.textContent = "Connected";
    status.className = "status connected";
    userInput.disabled = false;
    sendBtn.disabled = false;
    userInput.focus();
});

// Send on Enter (Shift+Enter for new line)
userInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        sendMessage();
    }
});

// Send button click
sendBtn.addEventListener("click", sendMessage);

// Auto-resize textarea
userInput.addEventListener("input", () => {
    userInput.style.height = "auto";
    userInput.style.height = Math.min(userInput.scrollHeight, 120) + "px";
});

function addMessage(role, text) {
    const div = document.createElement("div");
    div.className = "message " + role;
    div.textContent = text;
    messages.appendChild(div);
    messages.scrollTop = messages.scrollHeight;
    return div;
}

async function sendMessage() {
    const text = userInput.value.trim();
    if (!text || isGenerating) return;

    // Add user message
    addMessage("user", text);
    userInput.value = "";
    userInput.style.height = "auto";

    // Disable input while generating
    isGenerating = true;
    sendBtn.disabled = true;
    userInput.disabled = true;
    status.textContent = "Generating...";
    status.className = "status connecting";

    // Create assistant message bubble
    const assistantDiv = addMessage("assistant", "");

    try {
        // OpenAI-compatible chat completions endpoint (served by vLLM via nginx).
        // No conversation history yet — every send is a fresh [system, user] pair.
        const response = await fetch(API_URL + "/v1/chat/completions", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "x-api-key": apiKey
            },
            body: JSON.stringify({
                model: "google/gemma-4-E2B-it",
                messages: [
                    { role: "system", content: SYSTEM_PROMPT },
                    { role: "user",   content: text }
                ],
                temperature: 0.7,
                max_tokens: 512,
                stream: true
            })
        });

        // Handle errors
        if (response.status === 401) {
            assistantDiv.remove();
            addMessage("error", "Invalid API key. Refresh the page and try again.");
            resetInput();
            return;
        }

        if (response.status === 503) {
            // Cold start: no healthy task behind the ALB. Poll /health until ready.
            assistantDiv.textContent = "Warming up the GPU and loading the model. First request after idle can take 5–8 minutes. Please wait...";
            await retryUntilReady(text, assistantDiv);
            return;
        }

        if (!response.ok) {
            assistantDiv.remove();
            addMessage("error", "Error: " + response.status + " " + response.statusText);
            resetInput();
            return;
        }

        // Read SSE stream — OpenAI Chat Completions format:
        //   data: {"choices":[{"delta":{"role":"assistant"}}], ...}     <- initial chunk, ignored
        //   data: {"choices":[{"delta":{"content":"Hello"}}], ...}      <- token chunks
        //   ...
        //   data: {"choices":[{"delta":{}, "finish_reason":"stop"}], ...} <- end-of-message chunk
        //   data: {"choices":[], "usage":{...}}                          <- optional usage stats
        //   data: [DONE]
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let fullText = "";

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            const chunk = decoder.decode(value, { stream: true });
            const lines = chunk.split("\n");

            for (const line of lines) {
                if (!line.startsWith("data:")) continue;
                const data = line.slice(5).trim();
                if (data === "[DONE]") continue;

                try {
                    const parsed = JSON.parse(data);

                    // Final usage chunk: empty choices, optional usage stats.
                    // Log for observability and skip rendering.
                    if (parsed.usage && (!parsed.choices || parsed.choices.length === 0)) {
                        console.log("vLLM usage:", parsed.usage);
                        continue;
                    }

                    // Token text lives at choices[0].delta.content. The initial
                    // role chunk and the finish_reason chunk have no content; the
                    // empty-string check makes them no-ops automatically.
                    const piece = parsed.choices?.[0]?.delta?.content;
                    if (typeof piece === "string" && piece.length > 0) {
                        fullText += piece;
                        assistantDiv.textContent = fullText;
                        messages.scrollTop = messages.scrollHeight;
                    }
                } catch (e) {
                    // Skip malformed JSON lines
                }
            }
        }

        if (!fullText) {
            assistantDiv.textContent = "(Empty response)";
        }

    } catch (error) {
        assistantDiv.remove();
        if (error.name === "TypeError" && error.message.includes("Failed to fetch")) {
            addMessage("error", "Cannot reach the API. The service may be starting up. Please wait and try again.");
        } else {
            addMessage("error", "Error: " + error.message);
        }
    }

    resetInput();
}

async function retryUntilReady(text, messageDiv) {
    let attempts = 0;
    const maxAttempts = 40;   // 40 × 15 s = 10 min ceiling (cold start is realistically 6–8 min)

    // Switch the status pill from "Generating..." to "Warming up..." so the
    // user doesn't think the model is actively producing tokens during this wait.
    status.textContent = "Warming up...";
    status.className = "status connecting";

    while (attempts < maxAttempts) {
        attempts++;

        if (attempts === 1) {
            messageDiv.textContent = "Warming up the GPU and loading the model. First request after idle can take 5–8 minutes. Please wait...";
        } else {
            const elapsedMin = Math.round(attempts * 0.25);
            messageDiv.textContent =
                "Still warming up (attempt " + attempts + "/" + maxAttempts +
                ", ~" + elapsedMin + " min elapsed). " +
                "Your message will send automatically once the service is ready.";
        }
        messages.scrollTop = messages.scrollHeight;

        await new Promise(resolve => setTimeout(resolve, 15000));

        try {
            const response = await fetch(API_URL + "/health");
            if (response.ok) {
                messageDiv.remove();
                // Service is ready — re-stage the original prompt and re-send it
                userInput.value = text;
                isGenerating = false;
                sendBtn.disabled = false;
                userInput.disabled = false;
                sendMessage();
                return;
            }
        } catch (e) {
            // Still not ready
        }
    }

    messageDiv.remove();
    addMessage("error", "Service did not start after " + maxAttempts + " retries. Please try again later.");
    resetInput();
}

function resetInput() {
    isGenerating = false;
    sendBtn.disabled = false;
    userInput.disabled = false;
    status.textContent = "Connected";
    status.className = "status connected";
    userInput.focus();
}
