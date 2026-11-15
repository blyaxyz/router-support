const state = { routers: [], sessions: new Map() };
let terminalSocket = null;
const elements = {
  routers: document.querySelector('#routers'),
  message: document.querySelector('#message'),
  search: document.querySelector('#search'),
  total: document.querySelector('#total'),
  online: document.querySelector('#online'),
  offline: document.querySelector('#offline'),
  template: document.querySelector('#router-card'),
};

function requireAccess(response) {
  if (response.status === 403) {
    location.replace('/login');
    throw new Error('Доступ запрещён');
  }
  return response;
}

function relativeTime(value) {
  const seconds = Math.max(0, Math.round((Date.now() - new Date(value).getTime()) / 1000));
  if (seconds < 60) return `${seconds} сек. назад`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)} мин. назад`;
  return new Intl.DateTimeFormat('ru', { dateStyle: 'short', timeStyle: 'short' }).format(new Date(value));
}

function render() {
  const query = elements.search.value.trim().toLowerCase();
  const filtered = state.routers.filter((router) =>
    [router.uuid, router.name, router.model, router.mac_address || '']
      .some((value) => value.toLowerCase().includes(query))
  );
  elements.routers.replaceChildren();
  for (const router of filtered) {
    const card = elements.template.content.cloneNode(true);
    card.querySelector('h2').textContent = router.name;
    card.querySelector('.model').textContent = router.model || 'Модель не определена';
    card.querySelector('.uuid').textContent = router.uuid;
    card.querySelector('.firmware').textContent = router.firmware || '—';
    card.querySelector('.mac').textContent = router.mac_address || '—';
    card.querySelector('.port').textContent = `127.0.0.1:${router.ssh_port}`;
    card.querySelector('.seen').textContent = relativeTime(router.last_seen);
    const badge = card.querySelector('.status');
    badge.textContent = router.status === 'online' ? 'Онлайн' : 'Офлайн';
    badge.classList.add(router.status);
    card.querySelector('.rename').addEventListener('click', () => renameRouter(router));
    const button = card.querySelector('.support-button');
    const session = state.sessions.get(router.uuid);
    button.disabled = router.status !== 'online';
    button.textContent = session ? 'Завершить поддержку' : 'Начать поддержку';
    button.addEventListener('click', () => toggleSupport(router.uuid, button));
    if (session) {
      const links = card.querySelector('.support-links');
      for (const [label, url] of [
        ['LuCI', session.luci_url],
        ['V2RayA', session.v2raya_url],
        ['Web App', session.app_url],
      ].filter(([, url]) => url)) {
        const link = document.createElement('a');
        link.textContent = label;
        link.href = url;
        link.target = '_blank';
        link.rel = 'noopener';
        links.append(link);
      }
      const ssh = document.createElement('button');
      ssh.textContent = 'SSH';
      ssh.className = 'terminal-link';
      ssh.addEventListener('click', () => openTerminal(router));
      links.append(ssh);
    }
    elements.routers.append(card);
  }
  elements.total.textContent = state.routers.length;
  elements.online.textContent = state.routers.filter((router) => router.status === 'online').length;
  elements.offline.textContent = state.routers.filter((router) => router.status === 'offline').length;
  elements.message.textContent = filtered.length ? '' : 'Устройства не найдены';
}

async function renameRouter(router) {
  const hostname = window.prompt('Новый hostname (латиница, цифры и дефис)', router.name);
  if (!hostname || hostname === router.name) return;
  try {
    const response = await fetch(`/api/routers/${router.uuid}`, {
      method: 'PATCH',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ hostname }),
    });
    requireAccess(response);
    const result = await response.json();
    if (!response.ok) throw new Error(result.detail || `Ошибка переименования: ${response.status}`);
    router.name = result.hostname;
    render();
  } catch (error) {
    elements.message.textContent = error.message;
  }
}

function cleanTerminalText(value) {
  return value
    .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, '')
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\r(?!\n)/g, '');
}

async function openTerminal(router) {
  const dialog = document.querySelector('#terminal-dialog');
  const output = document.querySelector('#terminal-output');
  output.textContent = 'Подключение…\n';
  document.querySelector('#terminal-name').textContent = router.name;
  dialog.showModal();
  try {
    const response = await fetch(`/api/routers/${router.uuid}/terminal/ticket`, {
      method: 'POST',
    });
    requireAccess(response);
    const result = await response.json();
    if (!response.ok) throw new Error(result.detail || `Ошибка SSH: ${response.status}`);
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    terminalSocket = new WebSocket(`${scheme}://${location.host}/api/terminal/${result.ticket}`);
    terminalSocket.onopen = () => { output.textContent = ''; output.focus(); };
    terminalSocket.onmessage = (event) => {
      output.textContent += cleanTerminalText(event.data);
      output.scrollTop = output.scrollHeight;
    };
    terminalSocket.onclose = () => { output.textContent += '\n[SSH-сессия закрыта]\n'; };
  } catch (error) {
    output.textContent = `${error.message}\n`;
  }
}

async function toggleSupport(uuid, button) {
  button.disabled = true;
  const session = state.sessions.get(uuid);
  try {
    if (session) {
      const response = await fetch(`/api/sessions/${session.id}/stop`, {
        method: 'POST',
      });
      requireAccess(response);
      if (!response.ok) throw new Error(`Не удалось завершить сессию: ${response.status}`);
      state.sessions.delete(uuid);
    } else {
      const response = await fetch(`/api/routers/${uuid}/support/start`, {
        method: 'POST',
      });
      requireAccess(response);
      const result = await response.json();
      if (!response.ok) throw new Error(result.detail || `Ошибка запуска: ${response.status}`);
      state.sessions.set(uuid, result);
    }
    render();
  } catch (error) {
    elements.message.textContent = error.message;
    button.disabled = false;
  }
}

async function loadRouters() {
  elements.message.textContent = 'Загрузка…';
  try {
    const response = await fetch('/api/routers');
    requireAccess(response);
    if (!response.ok) throw new Error(`Ошибка API: ${response.status}`);
    state.routers = await response.json();
    render();
  } catch (error) {
    elements.message.textContent = error.message;
  }
}

document.querySelector('#refresh').addEventListener('click', loadRouters);
document.querySelector('#credentials').addEventListener('click', async () => {
  await fetch('/api/auth/logout', { method: 'POST' });
  location.replace('/login');
});
document.querySelector('#terminal-close').addEventListener('click', () => {
  if (terminalSocket) terminalSocket.close();
  terminalSocket = null;
  document.querySelector('#terminal-dialog').close();
});
document.querySelector('#terminal-output').addEventListener('keydown', (event) => {
  if (!terminalSocket || terminalSocket.readyState !== WebSocket.OPEN) return;
  const special = {
    Enter: '\r', Backspace: '\x7f', Tab: '\t', Escape: '\x1b',
    ArrowUp: '\x1b[A', ArrowDown: '\x1b[B', ArrowRight: '\x1b[C', ArrowLeft: '\x1b[D',
  };
  let data = special[event.key];
  if (event.ctrlKey && event.key.length === 1) {
    data = String.fromCharCode(event.key.toUpperCase().charCodeAt(0) - 64);
  } else if (!data && event.key.length === 1 && !event.metaKey && !event.altKey) {
    data = event.key;
  }
  if (data) { event.preventDefault(); terminalSocket.send(data); }
});
document.querySelector('#terminal-output').addEventListener('paste', (event) => {
  if (!terminalSocket || terminalSocket.readyState !== WebSocket.OPEN) return;
  event.preventDefault();
  terminalSocket.send(event.clipboardData.getData('text'));
});
elements.search.addEventListener('input', render);
loadRouters();
