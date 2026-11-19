const form = document.querySelector('#login-form');
const tokenInput = document.querySelector('#token');
const error = document.querySelector('#error');
const button = form.querySelector('button');

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  error.textContent = '';
  button.disabled = true;
  try {
    const response = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { Authorization: `Bearer ${tokenInput.value}` },
    });
    if (response.status === 403) {
      error.textContent = 'Ошибка 403: неверный токен доступа';
      tokenInput.select();
      return;
    }
    if (response.status === 429) {
      const seconds = Number(response.headers.get('Retry-After') || 300);
      const minutes = Math.max(1, Math.ceil(seconds / 60));
      error.textContent = `Слишком много попыток. Повторите через ${minutes} мин.`;
      return;
    }
    if (!response.ok) throw new Error(`Ошибка входа: ${response.status}`);
    location.replace('/');
  } catch (requestError) {
    error.textContent = requestError.message;
  } finally {
    button.disabled = false;
  }
});
