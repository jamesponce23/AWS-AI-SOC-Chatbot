const chatDiv = document.getElementById("chat");
const input = document.getElementById("queryInput");
const btn = document.getElementById("sendBtn");

// Replace with your API Gateway endpoint
const API_ENDPOINT = "https://68pv702j3h.execute-api.us-east-1.amazonaws.com/prod/analyze";

// Load chat history from localStorage
let chatHistory = JSON.parse(localStorage.getItem("chatHistory") || "[]");
chatHistory.forEach(msg => appendMessage(msg.text, msg.type, msg.timestamp));

// Append messages to chat UI
function appendMessage(text, type, timestamp = null) {
  const container = document.createElement("div");
  container.className = "message " + type;

  const msg = document.createElement("div");
  msg.style.whiteSpace = "pre-wrap";
  msg.textContent = text;

  const ts = document.createElement("span");
  ts.className = "timestamp";
  ts.textContent = timestamp || new Date().toLocaleTimeString();

  container.appendChild(msg);
  container.appendChild(ts);
  chatDiv.appendChild(container);
  chatDiv.scrollTop = chatDiv.scrollHeight;

  // Save to localStorage
  chatHistory.push({ text, type, timestamp: ts.textContent });
  localStorage.setItem("chatHistory", JSON.stringify(chatHistory));
}

// Send user query to Lambda API
async function sendQuery() {
  const query = input.value.trim();
  if (!query) return;
  input.value = "";

  appendMessage("You: " + query, "user");

  const typingIndicator = document.createElement("div");
  typingIndicator.className = "typing";
  typingIndicator.textContent = "SOC Copilot is typing...";
  chatDiv.appendChild(typingIndicator);
  chatDiv.scrollTop = chatDiv.scrollHeight;

  try {
    const response = await fetch(API_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query })
    });

    const data = await response.json();
    chatDiv.removeChild(typingIndicator);

    appendMessage(data.response || "No response from SOC Copilot.", "bot");
  } catch (err) {
    chatDiv.removeChild(typingIndicator);
    appendMessage("Error: " + err.message, "bot");
  }
}

// Event listeners
btn.addEventListener("click", sendQuery);
input.addEventListener("keydown", e => { if (e.key === "Enter") sendQuery(); });
