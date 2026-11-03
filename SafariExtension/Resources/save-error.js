document.getElementById("detail").textContent = new URLSearchParams(location.search).get("message") || "";
