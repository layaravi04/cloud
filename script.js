// PASTE your failover-router Function URL here after you create it in AWS.
const ROUTER_URL = "PASTE_FUNCTION_URL_HERE";

const servingEl = document.getElementById("serving-region");
const statusEl = document.getElementById("system-status");
const messageEl = document.getElementById("message");
const orderResultEl = document.getElementById("order-result");
const chaosToggle = document.getElementById("chaos-toggle");
const chaosMessage = document.getElementById("chaos-message");

let chaosBusy = false;

function routerBase() {
  return String(ROUTER_URL || "").trim().replace(/\/$/, "");
}

function isConfigured() {
  const url = routerBase();
  return url && url !== "PASTE_FUNCTION_URL_HERE";
}

async function readJson(response) {
  const text = await response.text();
  if (!text) {
    return {};
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    return { error: text };
  }
}

function setStatus(region, httpOk) {
  servingEl.textContent = region || "unavailable";
  servingEl.className = "";
  statusEl.className = "";

  if (!httpOk || !region) {
    statusEl.textContent = "UNAVAILABLE";
    statusEl.classList.add("down");
    return;
  }

  if (region === "us-east-1") {
    statusEl.textContent = "HEALTHY";
    statusEl.classList.add("healthy");
    servingEl.classList.add("healthy");
    return;
  }

  if (region === "us-west-2") {
    statusEl.textContent = "FAILOVER ACTIVE";
    statusEl.classList.add("failover");
    servingEl.classList.add("failover");
    return;
  }

  statusEl.textContent = "UNKNOWN";
}

async function refreshStatus() {
  if (!isConfigured()) {
    servingEl.textContent = "not configured";
    statusEl.textContent = "SET ROUTER_URL";
    messageEl.textContent =
      "Paste the failover-router Function URL into ROUTER_URL in frontend/script.js.";
    return;
  }

  messageEl.textContent = "Checking failover-router...";

  try {
    const response = await fetch(routerBase() + "/health", { method: "GET" });
    const data = await readJson(response);
    const region = data.served_by_region || data.region || null;
    setStatus(region, response.ok);
    messageEl.textContent = response.ok
      ? "Router responded from " + region + "."
      : data.error || "Router returned an error.";
  } catch (error) {
    setStatus(null, false);
    messageEl.textContent = "Could not reach router: " + error.message;
  }
}

async function refreshChaosState() {
  if (!isConfigured() || chaosBusy) {
    return;
  }

  try {
    const response = await fetch(routerBase() + "/chaos/status", { method: "GET" });
    const data = await readJson(response);
    const simulated = Boolean(data.failure_simulated);
    chaosToggle.checked = simulated;
    chaosMessage.textContent = simulated
      ? "East reserved concurrency is 0. Failover to us-west-2 should be active."
      : "East is enabled (unreserved concurrency).";
  } catch (error) {
    chaosMessage.textContent = "Could not read chaos status: " + error.message;
  }
}

async function setChaos(simulateFailure) {
  if (!isConfigured()) {
    chaosToggle.checked = false;
    chaosMessage.textContent = "Set ROUTER_URL first.";
    return;
  }

  chaosBusy = true;
  const path = simulateFailure ? "/chaos/fail-east" : "/chaos/recover-east";
  chaosMessage.textContent = simulateFailure
    ? "Disabling us-east-1..."
    : "Recovering us-east-1...";

  try {
    const response = await fetch(routerBase() + path, { method: "POST" });
    const data = await readJson(response);
    if (!response.ok) {
      chaosToggle.checked = !simulateFailure;
      chaosMessage.textContent = data.error || "Chaos action failed. Check router IAM permissions.";
      return;
    }
    chaosMessage.textContent = data.message || "Chaos action applied.";
    await new Promise(function (resolve) {
      setTimeout(resolve, 2500);
    });
    await refreshStatus();
    chaosBusy = false;
    await refreshChaosState();
  } catch (error) {
    chaosToggle.checked = !simulateFailure;
    chaosMessage.textContent = error.message;
  } finally {
    chaosBusy = false;
  }
}

async function createOrder() {
  if (!isConfigured()) {
    orderResultEl.textContent = "Set ROUTER_URL first.";
    return;
  }

  const body = {
    orderId: document.getElementById("order-id").value,
    customerId: document.getElementById("customer-id").value,
    productId: document.getElementById("product-id").value,
    quantity: 1,
  };

  try {
    const response = await fetch(routerBase() + "/orders", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await readJson(response);
    orderResultEl.textContent = JSON.stringify(data, null, 2);
    if (data.served_by_region) {
      setStatus(data.served_by_region, response.ok);
    }
  } catch (error) {
    orderResultEl.textContent = error.message;
  }
}

async function getOrder() {
  if (!isConfigured()) {
    orderResultEl.textContent = "Set ROUTER_URL first.";
    return;
  }

  const orderId = encodeURIComponent(document.getElementById("order-id").value);
  try {
    const response = await fetch(routerBase() + "/orders/" + orderId, { method: "GET" });
    const data = await readJson(response);
    orderResultEl.textContent = JSON.stringify(data, null, 2);
    if (data.served_by_region) {
      setStatus(data.served_by_region, response.ok);
    }
  } catch (error) {
    orderResultEl.textContent = error.message;
  }
}

document.getElementById("refresh").addEventListener("click", function () {
  refreshStatus();
  refreshChaosState();
});
document.getElementById("create-order").addEventListener("click", createOrder);
document.getElementById("get-order").addEventListener("click", getOrder);
chaosToggle.addEventListener("change", function () {
  setChaos(chaosToggle.checked);
});

refreshStatus();
refreshChaosState();
setInterval(function () {
  refreshStatus();
  refreshChaosState();
}, 8000);
