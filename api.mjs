export class Backend {
  constructor(config, storage = localStorage) {
    this.url = config.supabaseUrl.replace(/\/$/, '');
    this.key = config.supabaseKey;
    this.storage = storage;
    this.storageKey = `restock-session:${this.url}`;
    this.refreshing = null;
  }
  session() { try { return JSON.parse(this.storage.getItem(this.storageKey)); } catch { return null; } }
  save(data) {
    this.storage.setItem(this.storageKey, JSON.stringify({ access_token: data.access_token, refresh_token: data.refresh_token, expires_at: data.expires_at || Date.now()/1000 + data.expires_in, user: { id: data.user.id, email: data.user.email } }));
  }
  async request(path, body, token) {
    const response = await fetch(this.url + path, {
      method: 'POST', headers: { apikey: this.key, 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(body), signal: AbortSignal.timeout(15000), cache: 'no-store',
    });
    const data = await response.json().catch(() => null);
    if (!response.ok) {
      const e = new Error(data?.message || data?.msg || data?.error_description || '連線失敗，請稍後再試。');
      e.status = response.status; e.code = data?.code; throw e;
    }
    return data;
  }
  async login(email, password) { this.save(await this.request('/auth/v1/token?grant_type=password', { email, password })); }
  async token() {
    const refresh = async () => {
      const s = this.session();
      if (!s) throw new Error('請重新登入。');
      if (s.expires_at > Date.now()/1000 + 60) return s.access_token;
      try { this.save(await this.request('/auth/v1/token?grant_type=refresh_token', { refresh_token: s.refresh_token })); }
      catch (e) { if ([400,401,403].includes(e.status)) this.storage.removeItem(this.storageKey); throw e; }
      return this.session().access_token;
    };
    if (!this.refreshing) {
      this.refreshing = (globalThis.navigator?.locks ? navigator.locks.request(this.storageKey, refresh) : refresh()).finally(() => this.refreshing = null);
    }
    return this.refreshing;
  }
  async rpc(name, args = {}) { return this.request(`/rest/v1/rpc/${name}`, args, await this.token()); }
  async logout() {
    try { await this.request('/auth/v1/logout?scope=local', {}, await this.token()); }
    finally { this.storage.removeItem(this.storageKey); }
  }
}
