(() => {
  const root = document.documentElement;
  const motionOK = !window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const hasIO = "IntersectionObserver" in window;

  /* Reveal plates, text and tables once as they arrive. Without this script everything is simply visible. */
  if (hasIO && motionOK) {
    root.classList.add("reveal-on");
    const reveal = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("is-in");
        reveal.unobserve(entry.target);
      }
    }, { rootMargin: "0px 0px -10% 0px", threshold: 0.12 });
    document.querySelectorAll("[data-reveal]").forEach((el) => reveal.observe(el));
  }

  /* The actual-size sidebar: switch between example spaces */
  const atlas = document.querySelector(".atlas");
  if (atlas) {
    const buttons = [...atlas.querySelectorAll("[data-space-btn]")];
    const status = atlas.querySelector("[data-space-status]");
    const label = { personal: "Personal", work: "Work" };

    const setSpace = (name) => {
      if (atlas.dataset.space === name) return;
      atlas.dataset.space = name;
      buttons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.spaceBtn === name)));
      if (status) status.textContent = `Showing the ${label[name]} space.`;
    };

    buttons.forEach((b) => b.addEventListener("click", () => setSpace(b.dataset.spaceBtn)));
    // The dots in the drawn sidebar work too, for pointer users; the buttons above are the accessible control.
    atlas.querySelectorAll(".m-dots .d-personal, .m-dots .d-work").forEach((dot) => {
      dot.addEventListener("click", () => setSpace(dot.classList.contains("d-work") ? "work" : "personal"));
    });
  }

  /* Mark the section in view in the running head */
  const links = [...document.querySelectorAll(".head__nav a")];
  if (hasIO && links.length) {
    const spy = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        links.forEach((link) => {
          if (link.hash === "#" + entry.target.id) link.setAttribute("aria-current", "true");
          else link.removeAttribute("aria-current");
        });
      }
    }, { rootMargin: "-40% 0px -55% 0px" });
    ["top", "keyboard", "open-source", "download", ...links.map((l) => l.hash.slice(1))].forEach((id) => {
      const section = document.getElementById(id);
      if (section) spy.observe(section);
    });
  }
})();
