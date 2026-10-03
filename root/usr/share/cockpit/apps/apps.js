"use strict";

// path: where the Cockpit tunnel routes the app on this hostname.
// port: where the app listens on the LAN and tailnet.
const APPS = [
    { name: "Grafana", icon: "grafana.svg", path: "/grafana/", port: 3000 },
];

// The tunnel serves Cockpit on the default HTTPS port. Direct access always
// names port 9090.
function appUrl(app) {
    const loc = window.location;
    if (loc.port === "")
        return `${loc.origin}${app.path}`;
    return `http://${loc.hostname}:${app.port}${app.path}`;
}

// Same logic as Cockpit's own pages, which follow the shell's style setting.
function applyTheme(style) {
    style = style || localStorage.getItem("shell:style") || "auto";
    const dark = style === "dark" ||
        (style === "auto" && window.matchMedia("(prefers-color-scheme: dark)").matches);
    document.documentElement.classList.toggle("dark", dark);
}

window.addEventListener("storage", event => {
    if (event.key === "shell:style")
        applyTheme();
});
window.addEventListener("cockpit-style", event => applyTheme(event.detail?.style));
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => applyTheme());
applyTheme();

document.addEventListener("DOMContentLoaded", () => {
    const list = document.getElementById("apps");
    for (const app of APPS) {
        const link = document.createElement("a");
        link.href = appUrl(app);
        // Cockpit pages run in an iframe.
        link.target = "_blank";
        link.rel = "noopener";

        const icon = document.createElement("img");
        icon.src = app.icon;
        icon.alt = "";

        const label = document.createElement("span");
        label.textContent = app.name;

        link.append(icon, label);
        const item = document.createElement("li");
        item.append(link);
        list.append(item);
    }
});
