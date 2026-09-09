// PASTE your failover-router Function URL here after you create it in AWS.

const ROUTER_URL = "https://odg53jgahs6s7ru7qp5t3fmeky0ulfss.lambda-url.us-east-1.on.aws/";

const servingEl = document.getElementById("serving-region");
const statusEl = document.getElementById("system-status");
const messageEl = document.getElementById("message");
const orderResultEl = document.getElementById("order-result");

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
    const response = await fetch(routerBase() + "/health", {
      method: "GET"
    });

    const data = await readJson(response);

    const region =
      data.served_by_region ||
      data.region ||
      null;

    setStatus(region, response.ok);

    messageEl.textContent = response.ok
      ? "Router responded from " + region + "."
      : data.error || "Router returned an error.";

  } catch (error) {
    setStatus(null, false);
    messageEl.textContent =
      "Could not reach router: " + error.message;
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
    quantity: 1
  };

  try {
    const response = await fetch(routerBase() + "/orders", {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(body)
    });

    const data = await readJson(response);

    orderResultEl.textContent =
      JSON.stringify(data, null, 2);

    if (data.served_by_region) {
      setStatus(
        data.served_by_region,
        response.ok
      );
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

  const orderId =
    encodeURIComponent(
      document.getElementById("order-id").value
    );

  try {
    const response = await fetch(
      routerBase() + "/orders/" + orderId,
      {
        method: "GET"
      }
    );

    const data = await readJson(response);

    orderResultEl.textContent =
      JSON.stringify(data, null, 2);

    if (data.served_by_region) {
      setStatus(
        data.served_by_region,
        response.ok
      );
    }

  } catch (error) {
    orderResultEl.textContent = error.message;
  }
}

document
  .getElementById("refresh")
  .addEventListener("click", function () {
    refreshStatus();
  });

document
  .getElementById("create-order")
  .addEventListener("click", createOrder);

document
  .getElementById("get-order")
  .addEventListener("click", getOrder);

refreshStatus();

setInterval(function () {
  refreshStatus();
}, 8000);
