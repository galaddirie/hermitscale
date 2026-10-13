const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)")
const systemTheme = () => mediaQuery.matches ? "dark" : "light"

const setTheme = requestedTheme => {
  const theme = ["light", "dark"].includes(requestedTheme) ? requestedTheme : "system"

  if (theme === "system") {
    localStorage.removeItem("phx:theme")
    document.documentElement.setAttribute("data-theme", systemTheme())
    document.documentElement.setAttribute("data-theme-source", "system")
  } else {
    localStorage.setItem("phx:theme", theme)
    document.documentElement.setAttribute("data-theme", theme)
    document.documentElement.setAttribute("data-theme-source", "user")
  }
}

setTheme(localStorage.getItem("phx:theme") || "system")
window.addEventListener("storage", event => {
  if (event.key === "phx:theme") setTheme(event.newValue)
})
window.addEventListener("phx:set-theme", event => setTheme(event.target.dataset.phxTheme))
mediaQuery.addEventListener("change", () => {
  if (document.documentElement.getAttribute("data-theme-source") === "system") {
    document.documentElement.setAttribute("data-theme", systemTheme())
  }
})
