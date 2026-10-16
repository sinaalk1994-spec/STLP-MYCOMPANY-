(() => {
  if (location.origin !== 'https://tehbatri.ir') return;
  if (window.__tehranVoltMobileLayout) return;
  window.__tehranVoltMobileLayout = true;

  const style = document.createElement('style');
  style.id = 'tehran-volt-admin-mobile-layout';
  style.textContent = `
    html[data-tv-admin] [data-slot="dialog-content"] {
      min-width: 0;
      max-height: calc(100vh - 2rem);
      max-height: calc(100dvh - 2rem);
      grid-template-columns: minmax(0, 1fr);
      overflow-y: auto;
      overscroll-behavior-y: contain;
    }
    html[data-tv-admin] [data-slot="dialog-content"] form,
    html[data-tv-admin] [data-slot="textarea"] {
      min-width: 0;
      max-width: 100%;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    html[data-tv-news] .tv-news-card {
      min-width: 0;
      gap: 1rem;
    }
    html[data-tv-news] .tv-news-content {
      display: flex;
      flex: 1 1 0%;
      min-width: 0;
    }
    html[data-tv-news] .tv-news-text {
      flex: 1 1 0%;
      min-width: 0;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    html[data-tv-news] .tv-news-meta {
      min-width: 0;
      flex-wrap: wrap;
    }
    html[data-tv-news] .tv-news-meta [data-slot="badge"] {
      max-width: 100%;
      height: auto;
      min-height: 1.25rem;
      white-space: normal;
      overflow-wrap: anywhere;
      word-break: break-word;
    }
    html[data-tv-news] .tv-news-actions {
      display: flex;
      flex-shrink: 0;
      gap: .5rem;
      align-self: flex-start;
    }
    @media (max-width: 639px) {
      html[data-tv-news] .tv-news-card {
        flex-direction: column;
        align-items: stretch;
        gap: .75rem;
        padding: 1rem;
      }
      html[data-tv-news] .tv-news-content {
        flex: 0 1 auto;
        width: 100%;
        gap: .75rem;
      }
      html[data-tv-news] .tv-news-actions {
        align-self: flex-end;
        justify-content: flex-end;
        order: -1;
      }
      html[data-tv-news] .tv-news-actions button {
        width: 2.5rem;
        height: 2.5rem;
        min-width: 2.5rem;
        min-height: 2.5rem;
      }
    }
  `;
  document.head.appendChild(style);

  function updateLayout() {
    const root = document.documentElement;
    const isAdmin = /^\/admin(?:\/|$)/.test(location.pathname);
    const isNews = /^\/admin\/news\/?$/.test(location.pathname);
    root.toggleAttribute('data-tv-admin', isAdmin);
    root.toggleAttribute('data-tv-news', isNews);
    if (!isNews) return;
    const main = document.querySelector('main');
    if (!main) return;
    main.querySelectorAll('h3').forEach(heading => {
      let card = heading.parentElement;
      while (card && card !== main) {
        if (card.querySelector('svg.lucide-pencil') && card.querySelector('svg.lucide-trash-2')) break;
        card = card.parentElement;
      }
      if (!card || card === main) return;
      const children = Array.from(card.children);
      const content = children.find(child => child.contains(heading));
      const actions = children.find(child => child.querySelector('svg.lucide-pencil'));
      if (!content || !actions || content === actions) return;
      card.classList.add('tv-news-card');
      content.classList.add('tv-news-content');
      heading.parentElement.classList.add('tv-news-text');
      if (heading.previousElementSibling?.classList.contains('flex')) {
        heading.previousElementSibling.classList.add('tv-news-meta');
      }
      actions.classList.add('tv-news-actions');
      actions.querySelectorAll('button').forEach(button => {
        if (button.getAttribute('aria-label')) return;
        if (button.querySelector('svg.lucide-pencil')) button.setAttribute('aria-label', 'ویرایش خبر');
        else if (button.querySelector('svg.lucide-trash-2')) button.setAttribute('aria-label', 'حذف خبر');
      });
    });
  }

  let scheduled = false;
  new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => { scheduled = false; updateLayout(); });
  }).observe(document.documentElement, { childList: true, subtree: true });
  updateLayout();
})();
