/* Учебный пример и локальная подготовка заявки. */
(() => {
  'use strict';
  const workflow = document.querySelector('[data-workflow]');
  if (workflow) {
    const buttons = [...workflow.querySelectorAll('[data-step]')];
    const panels = [...workflow.querySelectorAll('[data-panel]')];
    const activate = (index) => {
      buttons.forEach((button, position) => button.setAttribute('aria-pressed', String(position === index)));
      panels.forEach((panel, position) => { panel.hidden = position !== index; });
    };
    workflow.classList.add('workflow-enhanced');
    activate(0);
    buttons.forEach((button, index) => button.addEventListener('click', () => activate(index)));
  }

  const form = document.getElementById('enrollment-form');
  const draftPanel = document.getElementById('draft-panel');
  if (!form || !draftPanel) return;

  const nameField = document.getElementById('participant-name');
  const questionField = document.getElementById('participant-question');
  const draftField = document.getElementById('draft-text');
  const draftHeading = document.getElementById('draft-heading');
  const draftLink = document.getElementById('telegram-draft-link');
  const draftStatus = document.getElementById('draft-status');
  const cleanText = (value) => value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();

  form.hidden = false;
  nameField.addEventListener('input', () => nameField.setCustomValidity(''));

  document.querySelectorAll('[data-interest]').forEach((link) => {
    link.addEventListener('click', () => {
      const option = [...form.querySelectorAll('input[name="interest"]')].find((input) => input.value === link.dataset.interest);
      if (option) option.checked = true;
      draftPanel.hidden = true;
      form.hidden = false;
    });
  });

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const name = cleanText(nameField.value);
    if (!name) {
      nameField.setCustomValidity('Укажите имя, чтобы Евгений знал, как к вам обратиться.');
      nameField.reportValidity();
      return;
    }
    const meeting = new FormData(form).get('interest') === 'meeting';
    const lines = [
      'Здравствуйте, Евгений! Меня зовут ' + name + '.',
      meeting
        ? 'Хочу записаться на бесплатную открытую встречу 21 ноября 2026 года с 10:00 до 11:00 МСК по курсу «Нейросети для проектирования: от чата до ассистента».'
        : 'Хочу записаться на курс «Нейросети для проектирования: от чата до ассистента» со стартом 28 ноября 2026 года. Подскажите наличие места, актуальную цену, условия участия и порядок оплаты по счёту.'
    ];
    const question = cleanText(questionField.value);
    if (question) lines.push('Моя задача или вопрос: ' + question);
    const draft = lines.join('\n\n');

    // Ввод пользователя выводится как текст. Никакой отправки на этом шаге нет.
    draftField.value = draft;
    const telegramUrl = new URL('https://t.me/EvgeniyKotzur');
    telegramUrl.searchParams.set('text', draft);
    draftLink.href = telegramUrl.href;
    draftStatus.textContent = '';
    form.hidden = true;
    draftPanel.hidden = false;
    draftPanel.scrollIntoView({ block: 'start', behavior: 'instant' });
    draftHeading.focus({ preventScroll: true });
  });

  document.getElementById('copy-draft').addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(draftField.value);
      draftStatus.textContent = 'Текст скопирован. Вставьте его в чат с Евгением.';
    } catch {
      draftField.focus();
      draftField.select();
      draftStatus.textContent = 'Текст выделен. Скопируйте его через меню устройства или Ctrl+C.';
    }
  });

  document.getElementById('edit-draft').addEventListener('click', () => {
    draftPanel.hidden = true;
    form.hidden = false;
    form.scrollIntoView({ block: 'start', behavior: 'instant' });
    nameField.focus({ preventScroll: true });
  });

  // Ссылка из подвала раскрывает условия и при обычной навигации, и по прямому адресу.
  const revealTerms = () => {
    if (window.location.hash === '#terms') document.getElementById('terms').open = true;
  };
  window.addEventListener('hashchange', revealTerms);
  document.querySelectorAll('a[href="#terms"]').forEach((link) => {
    link.addEventListener('click', () => { document.getElementById('terms').open = true; });
  });
  revealTerms();
})();
