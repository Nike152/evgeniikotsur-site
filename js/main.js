// ============================================
// Поведение страницы: валидация формы
// ============================================
// Плавный скролл по якорям — делает сам браузер
// через CSS-свойство scroll-behavior: smooth
// в style.css. JS-кода для скролла не нужно.

document.addEventListener('DOMContentLoaded', () => {

    const form = document.querySelector('.contact-form');
    if (!form) return;

    const errorBox = document.getElementById('form-error');
    const fields = {
        name: form.querySelector('#name'),
        email: form.querySelector('#email'),
        message: form.querySelector('#message')
    };

    // Простая проверка email — без перфекционизма,
    // достаточно отсечь явные опечатки. Финальную
    // валидацию всё равно делает Formspree.
    const emailLooksValid = (value) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);

    // Сброс подсветки ошибок при вводе
    Object.values(fields).forEach((field) => {
        field.addEventListener('input', () => {
            field.classList.remove('is-invalid');
            errorBox.textContent = '';
        });
    });

    form.addEventListener('submit', (event) => {
        // Сначала собираем все ошибки, только потом решаем — пускать или блокировать
        let firstError = '';

        // имя
        if (!fields.name.value.trim()) {
            fields.name.classList.add('is-invalid');
            firstError = firstError || 'Укажите имя.';
        }

        // email
        const emailValue = fields.email.value.trim();
        if (!emailValue) {
            fields.email.classList.add('is-invalid');
            firstError = firstError || 'Укажите email.';
        } else if (!emailLooksValid(emailValue)) {
            fields.email.classList.add('is-invalid');
            firstError = firstError || 'Похоже, в email есть опечатка.';
        }

        // сообщение
        if (!fields.message.value.trim()) {
            fields.message.classList.add('is-invalid');
            firstError = firstError || 'Напишите пару слов о задаче.';
        }

        if (firstError) {
            event.preventDefault(); // блокируем отправку на Formspree
            errorBox.textContent = firstError;
        }
        // если ошибок нет — браузер сам отправит форму на action из HTML
    });
});
