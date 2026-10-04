if ('IntersectionObserver' in window && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      }
    }
  }, { threshold: 0.08 });

  document.querySelectorAll('.hero > *, .section-heading, .workflow-card, .details-grid article, .start-steps li').forEach((element, index) => {
    element.classList.add('reveal-item');
    element.style.setProperty('--reveal-delay', `${index % 3 * 80}ms`);
    observer.observe(element);
  });
  document.documentElement.classList.add('reveal-enabled');
}

if (matchMedia('(hover: hover) and (pointer: fine)').matches) {
  document.querySelectorAll('.workflow-card').forEach(card => {
    card.addEventListener('pointermove', event => {
      const bounds = card.getBoundingClientRect();
      card.style.setProperty('--spot-x', `${event.clientX - bounds.left}px`);
      card.style.setProperty('--spot-y', `${event.clientY - bounds.top}px`);
      card.style.setProperty('--spot-opacity', '1');
    });
    card.addEventListener('pointerleave', () => card.style.setProperty('--spot-opacity', '0'));
  });
}
