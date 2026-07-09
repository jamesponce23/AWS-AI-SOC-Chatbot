const chatDiv = document.getElementById("chat");
const input = document.getElementById("queryInput");
const btn = document.getElementById("sendBtn");
const loginBtn = document.getElementById("loginBtn");
const logoutBtn = document.getElementById("logoutBtn");
const userLabel = document.getElementById("userLabel");

// Injected at deploy time by Terraform (see s3.tf -> config.js).
const CONFIG = window.SOC_CONFIG || {};
const API_ENDPOINT = CONFIG.apiEndpoint;

// ============================================================
// Cognito auth (Authorization Code + PKCE, public client)
// ============================================================
const TOKENS_KEY = "socTokens";

function getTokens() {
  try {
    return JSON.parse(sessionStorage.getItem(TOKENS_KEY) || "null");
  } catch {
    return null;
  }
}

function saveTokens(t) {
  // Record absolute expiry so we can refresh proactively.
  t.expiresAt = Date.now() + (t.expires_in || 3600) * 1000;
  sessionStorage.setItem(TOKENS_KEY, JSON.stringify(t));
}

function clearTokens() {
  sessionStorage.removeItem(TOKENS_KEY);
}

function decodeJwt(token) {
  try {
    const payload = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(payload));
  } catch {
    return {};
  }
}

// --- PKCE helpers ---
function randomString(len = 64) {
  const bytes = new Uint8Array(len);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, b => ("0" + b.toString(16)).slice(-2)).join("");
}

function base64UrlEncode(buffer) {
  return btoa(String.fromCharCode(...new Uint8Array(buffer)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function pkceChallenge(verifier) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64UrlEncode(digest);
}

async function login() {
  const verifier = randomString();
  sessionStorage.setItem("pkceVerifier", verifier);
  const challenge = await pkceChallenge(verifier);

  const params = new URLSearchParams({
    response_type: "code",
    client_id: CONFIG.clientId,
    redirect_uri: CONFIG.redirectUri,
    scope: CONFIG.scopes,
    code_challenge: challenge,
    code_challenge_method: "S256"
  });
  window.location.assign(`${CONFIG.cognitoDomain}/oauth2/authorize?${params}`);
}

function logout() {
  clearTokens();
  const params = new URLSearchParams({
    client_id: CONFIG.clientId,
    logout_uri: CONFIG.redirectUri
  });
  window.location.assign(`${CONFIG.cognitoDomain}/logout?${params}`);
}

async function exchangeCodeForTokens(code) {
  const verifier = sessionStorage.getItem("pkceVerifier");
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: CONFIG.clientId,
    code,
    redirect_uri: CONFIG.redirectUri,
    code_verifier: verifier
  });
  const resp = await fetch(`${CONFIG.cognitoDomain}/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body
  });
  if (!resp.ok) throw new Error("Token exchange failed");
  saveTokens(await resp.json());
  sessionStorage.removeItem("pkceVerifier");
}

async function refreshTokens() {
  const t = getTokens();
  if (!t || !t.refresh_token) return false;
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: CONFIG.clientId,
    refresh_token: t.refresh_token
  });
  const resp = await fetch(`${CONFIG.cognitoDomain}/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body
  });
  if (!resp.ok) return false;
  const fresh = await resp.json();
  // Refresh response omits the refresh_token itself — keep the existing one.
  fresh.refresh_token = fresh.refresh_token || t.refresh_token;
  saveTokens(fresh);
  return true;
}

// Returns a valid ID token, refreshing if needed, or null if not logged in.
async function getIdToken() {
  let t = getTokens();
  if (!t) return null;
  if (Date.now() < t.expiresAt - 30000) return t.id_token;
  if (await refreshTokens()) return getTokens().id_token;
  clearTokens();
  return null;
}

function isLoggedIn() {
  return !!getTokens();
}

function updateAuthUI() {
  if (isLoggedIn()) {
    const claims = decodeJwt(getTokens().id_token);
    userLabel.textContent = claims.email || claims["cognito:username"] || "Signed in";
    loginBtn.style.display = "none";
    logoutBtn.style.display = "";
    input.disabled = false;
    btn.disabled = false;
  } else {
    userLabel.textContent = "Not signed in";
    loginBtn.style.display = "";
    logoutBtn.style.display = "none";
    input.disabled = true;
    btn.disabled = true;
  }
}

// ============================================================
// Chat UI
// ============================================================
let chatHistory = JSON.parse(localStorage.getItem("chatHistory") || "[]");
chatHistory.forEach(msg => appendMessage(msg.text, msg.type, msg.timestamp, false));

// persist=false when replaying already-stored history, so we don't
// re-append it (which previously doubled localStorage on every load).
function appendMessage(text, type, timestamp = null, persist = true) {
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

  if (persist) {
    chatHistory.push({ text, type, timestamp: ts.textContent });
    localStorage.setItem("chatHistory", JSON.stringify(chatHistory));
  }
}

async function sendQuery() {
  const query = input.value.trim();
  if (!query) return;

  const idToken = await getIdToken();
  if (!idToken) {
    appendMessage("Your session has expired. Please log in again.", "bot");
    updateAuthUI();
    return;
  }

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
      headers: {
        "Content-Type": "application/json",
        // REST API Cognito authorizer expects the raw JWT (no "Bearer " prefix).
        "Authorization": idToken
      },
      body: JSON.stringify({ query })
    });

    chatDiv.removeChild(typingIndicator);

    if (response.status === 401 || response.status === 403) {
      clearTokens();
      updateAuthUI();
      appendMessage("Not authorized. Please log in again.", "bot");
      return;
    }

    const data = await response.json();
    appendMessage(data.response || "No response from SOC Copilot.", "bot");
  } catch (err) {
    chatDiv.removeChild(typingIndicator);
    appendMessage("Error: " + err.message, "bot");
  }
}

// ============================================================
// Bootstrap
// ============================================================
btn.addEventListener("click", sendQuery);
input.addEventListener("keydown", e => { if (e.key === "Enter") sendQuery(); });
loginBtn.addEventListener("click", login);
logoutBtn.addEventListener("click", logout);

(async function init() {
  // Handle the redirect back from Cognito hosted UI (?code=...).
  const url = new URL(window.location.href);
  const code = url.searchParams.get("code");
  if (code) {
    try {
      await exchangeCodeForTokens(code);
    } catch (e) {
      console.error(e);
    }
    // Strip the code from the address bar.
    window.history.replaceState({}, document.title, url.origin + url.pathname);
  }
  updateAuthUI();
})();
