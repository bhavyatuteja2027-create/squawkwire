'use client';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { supabaseBrowser } from '@/lib/supabaseBrowser';

const CATS = ['Macro', 'Central Banks', 'Equities', 'FX', 'Commodities', 'Crypto', 'World', 'Filings'];
const CHANNELS = [['in_app', 'In-app'], ['email', 'Email'], ['push', 'Push'], ['webhook', 'Webhook'], ['telegram', 'Telegram']];
const PLAN_CARDS = [
  { code: 'retail', name: 'Retail', price: '$9.99/mo', perks: ['Live data (no delay)', '25 keywords', 'Email alerts', 'Up to 5 tabs'] },
  { code: 'pro', name: 'Pro', price: '$49/mo', perks: ['Everything in Retail', 'Unlimited keywords & widgets', 'Push, Telegram & webhook alerts', 'Priority support'] },
];

// ---- pure helpers (ported verbatim in spirit) ----
const tsOf = (i) => new Date(i.published_at).getTime() / 1000;
const hhmm = (ts) => new Date(ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
const ago = (ts) => { const m = Math.max(0, Math.round(Date.now() / 1000 - ts) / 60 | 0); return m < 1 ? 'now' : m < 60 ? `${m}m` : `${Math.round(m / 60)}h`; };
const safe = (u) => (/^https?:\/\//i.test(u) ? u : '#');
const money = (cents, ccy) => (ccy ? `${ccy.toUpperCase()} ` : '$') + ((cents || 0) / 100).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const matchKw = (kws, title) => kws.some((k) => new RegExp('\\b' + k.term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b', 'i').test(title));

function chime() {
  try {
    const a = new (window.AudioContext || window.webkitAudioContext)(), t = a.currentTime;
    [660, 880].forEach((f, i) => { const o = a.createOscillator(), g = a.createGain(); o.frequency.value = f; o.connect(g); g.connect(a.destination); g.gain.setValueAtTime(0.15, t + i * 0.15); g.gain.exponentialRampToValueAtTime(0.001, t + i * 0.15 + 0.14); o.start(t + i * 0.15); o.stop(t + i * 0.15 + 0.15); });
  } catch (e) { /* ignore */ }
}

export default function Terminal() {
  const sb = useMemo(() => supabaseBrowser(), []);
  const [session, setSession] = useState(undefined); // undefined = loading
  const [ent, setEnt] = useState({ delay_seconds: 86400, channels: ['in_app'], max_widgets: 3, max_keywords: 3, max_tabs: 1 });
  const [items, setItems] = useState([]);
  const [entByItem, setEntByItem] = useState({});
  const [freshIds, setFreshIds] = useState(new Set());
  const [tabs, setTabs] = useState([]);
  const [activeTab, setActiveTab] = useState(null);
  const [kws, setKws] = useState([]);
  const [rules, setRules] = useState([]);
  const [view, setView] = useState('dash');
  const [sq, setSq] = useState(false);
  const [squawkAll, setSquawkAll] = useState(false);
  const [query, setQuery] = useState('');
  const [stat, setStat] = useState('Connecting…');
  const [billing, setBilling] = useState(null);
  const [isAdmin, setIsAdmin] = useState(false);
  const [adminData, setAdminData] = useState(null);
  const [toasts, setToasts] = useState([]);
  const [dlg, setDlg] = useState(null); // {editingId|null, title, cat, src, kw}

  const seen = useRef(null);
  const sqRef = useRef(false); const squawkAllRef = useRef(false);
  const rtItems = useRef(null); const rtAlerts = useRef(null); const backfilled = useRef(new Set());
  const entRef = useRef(ent);
  useEffect(() => { sqRef.current = sq; }, [sq]);
  useEffect(() => { squawkAllRef.current = squawkAll; }, [squawkAll]);
  useEffect(() => { entRef.current = ent; }, [ent]);

  const isPaid = Number(ent.delay_seconds) === 0;

  const hot = useCallback((i) => matchKw(kws, i.title) || Math.abs(i.score) >= 0.5, [kws]);

  const speak = useCallback((list) => {
    if (!sqRef.current || typeof window === 'undefined' || !window.speechSynthesis) return;
    const pick = (squawkAllRef.current ? list : list.filter((i) => matchKw(kws, i.title) || Math.abs(i.score) >= 0.5)).slice(0, 3);
    if (!pick.length) return;
    chime();
    pick.forEach((i) => window.speechSynthesis.speak(new SpeechSynthesisUtterance(`${i.cat || i.category}. ${i.title}`)));
  }, [kws]);

  // ---------- data loading ----------
  const loadItems = useCallback(async () => {
    const { data, error } = await sb.rpc('feed_items', { p_limit: 400 });
    if (error) { setStat('Could not load headlines'); return; }
    const incoming = data || [];
    if (seen.current) { const nw = incoming.filter((i) => !seen.current.has(i.id)); setFreshIds(new Set(nw.map((i) => i.id))); speak(nw); }
    seen.current = new Set(incoming.map((i) => i.id));
    setItems(incoming);
    try {
      const { data: ents } = await sb.rpc('feed_entities', { p_item_ids: incoming.map((i) => i.id) });
      const map = {}; (ents || []).forEach((e) => { (map[e.item_id] = map[e.item_id] || []).push({ ticker: e.ticker, company: e.company_name }); });
      setEntByItem(map);
    } catch (e) { setEntByItem({}); }
    const latest = incoming[0] ? tsOf(incoming[0]) : Date.now() / 1000;
    const paid = Number(entRef.current.delay_seconds) === 0;
    setStat(`${incoming.length} headlines${incoming.length ? ` · newest ${ago(latest)} ago` : ''}${paid ? '' : ' · 24h delayed (Free)'}`);
  }, [sb, speak]);

  const loadWorkspace = useCallback(async () => {
    const { data: e } = await sb.rpc('my_entitlements'); if (e) setEnt(e);
    const entNow = e || entRef.current;
    const { data: dash } = await sb.from('dashboards').select('id,name,position').order('position');
    let t = dash || [];
    if (!t.length) {
      const { data: nd } = await sb.from('dashboards').insert({ name: 'Dashboard', position: 0 }).select().single();
      if (nd) {
        t = [nd];
        const starter = [{ title: 'Headlines', category: null }, { title: 'Central banks', category: 'Central Banks' }, { title: 'SEC filings', category: 'Filings' }, { title: 'World events', category: 'World' }]
          .slice(0, entNow.max_widgets || 3).map((w, idx) => ({ dashboard_id: nd.id, title: w.title, category: w.category, position: idx }));
        await sb.from('widgets').insert(starter);
      }
    }
    const ids = t.map((x) => x.id);
    const { data: wids } = await sb.from('widgets').select('id,dashboard_id,title,category,source_name,keyword,position')
      .in('dashboard_id', ids.length ? ids : ['00000000-0000-0000-0000-000000000000']).order('position');
    const built = t.map((x) => ({ id: x.id, name: x.name, widgets: (wids || []).filter((w) => w.dashboard_id === x.id).map((w) => ({ id: w.id, title: w.title, cat: w.category || '', src: w.source_name || '', kw: w.keyword || '' })) }));
    setTabs(built); setActiveTab(built[0]?.id || null);
    const { data: kwRows } = await sb.from('watch_keywords').select('id,term').order('created_at'); setKws(kwRows || []);
    const { data: ruleRows } = await sb.from('alert_rules').select('id,term,min_abs_score,channels,enabled').order('created_at'); setRules(ruleRows || []);
  }, [sb]);

  // ---------- realtime ----------
  const startRealtime = useCallback(() => {
    if (!isPaid || rtItems.current) return;
    rtItems.current = sb.channel('items-live').on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'items' }, () => loadItems()).subscribe();
  }, [sb, isPaid, loadItems]);

  const pushToast = useCallback((p) => {
    const id = Math.random().toString(36).slice(2);
    setToasts((ts) => [...ts, { id, ...p }]);
    chime();
    if (sqRef.current && window.speechSynthesis) window.speechSynthesis.speak(new SpeechSynthesisUtterance(`${p.category || ''}. ${p.title || ''}`));
    setTimeout(() => setToasts((ts) => ts.filter((x) => x.id !== id)), 8000);
  }, []);

  const startAlerts = useCallback(() => {
    if (rtAlerts.current) return;
    rtAlerts.current = sb.channel('alerts-live').on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'alert_deliveries', filter: 'channel=eq.in_app' },
      (payload) => { const row = payload.new; if (row && !backfilled.current.has(row.id)) { backfilled.current.add(row.id); pushToast(row.payload || {}); } }).subscribe();
  }, [sb, pushToast]);

  // ---------- auth lifecycle ----------
  useEffect(() => {
    let mounted = true;
    sb.auth.getSession().then(({ data }) => { if (mounted) setSession(data.session || null); });
    const { data: sub } = sb.auth.onAuthStateChange((_e, s) => setSession(s || null));
    return () => { mounted = false; sub.subscription.unsubscribe(); };
  }, [sb]);

  useEffect(() => {
    if (!session) {
      if (rtItems.current) { sb.removeChannel(rtItems.current); rtItems.current = null; }
      if (rtAlerts.current) { sb.removeChannel(rtAlerts.current); rtAlerts.current = null; }
      seen.current = null; backfilled.current = new Set();
      return;
    }
    (async () => {
      await loadWorkspace();
      await loadItems();
      try { const { data: a } = await sb.rpc('my_is_admin'); setIsAdmin(!!a); } catch (e) { setIsAdmin(false); }
      handleBillingReturn();
    })();
  }, [session]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { if (session) { startRealtime(); startAlerts(); } }, [session, isPaid, startRealtime, startAlerts]);

  useEffect(() => {
    if (!session) return;
    const id = setInterval(() => loadItems(), 60000);
    return () => clearInterval(id);
  }, [session, loadItems]);

  function handleBillingReturn() {
    if (typeof window === 'undefined') return;
    const u = new URL(window.location.href); const b = u.searchParams.get('billing');
    if (!b) return; u.searchParams.delete('billing'); window.history.replaceState({}, '', u.toString());
    if (b === 'success') setTimeout(async () => { const { data: e } = await sb.rpc('my_entitlements'); if (e) { setEnt(e); loadItems(); } }, 4000);
  }

  // ---------- derived ----------
  const curTab = tabs.find((t) => t.id === activeTab) || tabs[0] || { widgets: [] };
  const sources = useMemo(() => [...new Set(items.map((i) => i.source_name))].sort(), [items]);
  const filterItems = (w) => {
    const q = query.toLowerCase(), k = (w.kw || '').toLowerCase();
    return items.filter((i) => (!w.cat || i.category === w.cat) && (!w.src || i.source_name === w.src) && (!k || i.title.toLowerCase().includes(k)) && (!q || i.title.toLowerCase().includes(q))).slice(0, 120);
  };

  // ---------- mutations ----------
  const addTab = async () => {
    if (tabs.length >= (ent.max_tabs || 1)) { alert(`Your plan allows ${ent.max_tabs || 1} tab(s). Upgrade for more.`); return; }
    const n = prompt('Tab name'); if (!n) return;
    const { data } = await sb.from('dashboards').insert({ name: n.slice(0, 24), position: tabs.length }).select().single();
    if (data) { setTabs((ts) => [...ts, { id: data.id, name: data.name, widgets: [] }]); setActiveTab(data.id); }
  };
  const delTab = async () => {
    if (!confirm('Delete this tab?')) return; const id = activeTab;
    await sb.from('dashboards').delete().eq('id', id);
    setTabs((ts) => { const next = ts.filter((x) => x.id !== id); setActiveTab(next[0]?.id || null); return next; });
  };
  const saveWidget = async () => {
    const v = { title: (dlg.title || '').trim() || 'Widget', cat: dlg.cat || '', src: dlg.src || '', kw: (dlg.kw || '').trim() };
    if (dlg.editingId) {
      await sb.from('widgets').update({ title: v.title, category: v.cat || null, source_name: v.src || null, keyword: v.kw || null }).eq('id', dlg.editingId);
      setTabs((ts) => ts.map((t) => t.id === curTab.id ? { ...t, widgets: t.widgets.map((w) => w.id === dlg.editingId ? { ...w, ...v } : w) } : t));
    } else {
      if (curTab.widgets.length >= (ent.max_widgets || 3)) { alert(`Your plan allows ${ent.max_widgets || 3} widgets. Upgrade for more.`); return; }
      const { data } = await sb.from('widgets').insert({ dashboard_id: curTab.id, title: v.title, category: v.cat || null, source_name: v.src || null, keyword: v.kw || null, position: curTab.widgets.length }).select().single();
      if (data) setTabs((ts) => ts.map((t) => t.id === curTab.id ? { ...t, widgets: [...t.widgets, { id: data.id, title: data.title, cat: data.category || '', src: data.source_name || '', kw: data.keyword || '' }] } : t));
    }
    setDlg(null);
  };
  const removeWidget = async (w) => {
    setTabs((ts) => ts.map((t) => t.id === curTab.id ? { ...t, widgets: t.widgets.filter((y) => y.id !== w.id) } : t));
    await sb.from('widgets').delete().eq('id', w.id);
  };
  const addKw = async (term) => {
    const v = term.trim().slice(0, 30); if (!v || kws.some((k) => k.term === v)) return;
    if (kws.length >= (ent.max_keywords || 3)) { alert(`Your plan allows ${ent.max_keywords || 3} keywords. Upgrade for more.`); return; }
    const { data } = await sb.from('watch_keywords').insert({ term: v }).select().single();
    if (data) setKws((k) => [...k, { id: data.id, term: data.term }]);
  };
  const removeKw = async (w) => { setKws((k) => k.filter((x) => x.id !== w.id)); await sb.from('watch_keywords').delete().eq('id', w.id); };

  // ---------- billing ----------
  const apiPost = async (path, body) => {
    const { data: { session: s } } = await sb.auth.getSession(); if (!s) return { error: 'unauthorized' };
    const r = await fetch(path, { method: 'POST', headers: { Authorization: `Bearer ${s.access_token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
    return r.json().catch(() => ({ error: 'bad_response' }));
  };
  const startCheckout = async (code) => { const j = await apiPost('/api/billing/checkout', { plan: code }); if (j.url) window.location.href = j.url; else alert('Could not start checkout' + (j.error ? `: ${j.error}` : '')); };
  const openPortal = async () => { const j = await apiPost('/api/billing/portal'); if (j.url) window.location.href = j.url; else alert('Billing portal unavailable' + (j.error ? `: ${j.error}` : '')); };
  const loadBilling = useCallback(async () => { const { data } = await sb.rpc('my_billing'); setBilling(data || { plan_code: 'free', plan_name: 'Free', status: 'active' }); }, [sb]);
  useEffect(() => { if (view === 'billing' && session) loadBilling(); }, [view, session, loadBilling]);

  // ---------- admin ----------
  const loadAdmin = useCallback(async () => {
    try {
      const [{ data: rev }, { data: us }, { data: src }] = await Promise.all([sb.rpc('admin_revenue'), sb.rpc('admin_user_stats'), sb.rpc('admin_source_health')]);
      setAdminData({ rev, us, src: src || [] });
    } catch (e) { setAdminData({ error: 'Not authorized.' }); }
  }, [sb]);
  useEffect(() => { if (view === 'admin' && session) loadAdmin(); }, [view, session, loadAdmin]);

  const toggleSquawk = () => { setSq((s) => { const n = !s; if (n) chime(); return n; }); };

  if (session === undefined) return <div className="gate"><div className="card">Loading…</div></div>;
  if (!session) return <Gate sb={sb} />;

  return (
    <div className="app">
      <nav aria-label="Main">
        <button className={`sqb${sq ? ' on' : ''}`} aria-pressed={sq} onClick={toggleSquawk}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M11 5 6 9H2v6h4l5 4z" />
            <path d={sq ? 'M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13' : 'M16 9l5 6M21 9l-5 6'} />
          </svg>
          <span>{sq ? 'Squawk on' : 'Start Squawk'}</span>
        </button>
        {[['dash', 'Dashboard'], ['watch', 'Watchlists'], ['billing', 'Billing']].map(([v, label]) => (
          <button key={v} className="nv" aria-current={view === v ? 'page' : undefined} onClick={() => setView(v)}>{label}</button>
        ))}
        {isAdmin && <button className="nv" aria-current={view === 'admin' ? 'page' : undefined} onClick={() => setView('admin')}>Admin</button>}
        <div className="logo">Squawk<br />wire</div>
      </nav>

      <div className="mainp">
        <div className="bar">
          <span><i />{<b>{isPaid ? 'LIVE DATA' : 'OPEN DATA'}</b>}</span>
          <span>{stat}</span>
          <input type="search" placeholder="Search all widgets" aria-label="Search headlines" value={query} onChange={(e) => setQuery(e.target.value)} />
          <button className="btn g" style={{ padding: '6px 10px' }} onClick={() => sb.auth.signOut()}>Log out</button>
        </div>
        {!isPaid && <div className="upsell"><b>Free plan:</b> headlines are delayed 24 hours. Upgrade for live data, alerts and more widgets.</div>}

        {view === 'dash' && (
          <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0 }}>
            <div className="tabs" role="tablist">
              {tabs.map((t) => (
                <button key={t.id} className="tab" role="tab" aria-selected={t.id === activeTab} onClick={() => setActiveTab(t.id)}>{t.name}</button>
              ))}
              <button className="tab add" onClick={addTab}>+ Add tab</button>
              <div className="sp">
                <button className="tab" onClick={() => setDlg({ editingId: null, title: '', cat: '', src: '', kw: '' })}>+ Add widget</button>
                {tabs.length > 1 && <button className="tab" onClick={delTab}>Delete tab</button>}
              </div>
            </div>
            <div className="board">
              {!curTab.widgets.length && <div className="empty">No widgets in this tab. Use &quot;+ Add widget&quot;.</div>}
              {curTab.widgets.map((w) => {
                const list = filterItems(w);
                return (
                  <section className="w" key={w.id}>
                    <div className="wh">
                      <span>{w.title}</span><span className="bd">{isPaid ? 'live' : '24h delay'}</span>
                      <div className="ic">
                        <button title="Edit" aria-label={`Edit ${w.title}`} onClick={() => setDlg({ editingId: w.id, title: w.title, cat: w.cat, src: w.src, kw: w.kw })}>⚙</button>
                        <button title="Remove" aria-label={`Remove ${w.title}`} onClick={() => removeWidget(w)}>×</button>
                      </div>
                    </div>
                    <div className="wl">
                      {!list.length && <div className="empty">{items.length ? 'Nothing matches this widget.' : 'No data yet.'}</div>}
                      {list.map((i) => <Row key={i.id} i={i} hot={hot(i)} fresh={freshIds.has(i.id)} tickers={entByItem[i.id]} />)}
                    </div>
                  </section>
                );
              })}
            </div>
          </div>
        )}

        {view === 'watch' && (
          <Watchlists items={items} kws={kws} rules={rules} setRules={setRules} ent={ent} sb={sb}
            addKw={addKw} removeKw={removeKw} squawkAll={squawkAll} setSquawkAll={setSquawkAll}
            entByItem={entByItem} />
        )}

        {view === 'billing' && (
          <div className="page">
            <div className="card"><h2>Your plan</h2>
              <p className="chk" style={{ margin: 0 }}>{billing ? `Current plan: ${billing.plan_name} · status: ${billing.status}${billing.current_period_end ? ` · ${billing.cancel_at_period_end ? 'ends' : 'renews'} ${new Date(billing.current_period_end).toLocaleDateString()}` : ''}` : 'Loading…'}</p>
              {billing?.has_customer && <div className="row" style={{ marginTop: 12 }}><button className="btn g" onClick={openPortal}>Manage billing</button></div>}
            </div>
            <div className="card"><h2>Plans</h2>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
                {PLAN_CARDS.map((p) => {
                  const cur = billing?.plan_code === p.code;
                  return (
                    <div className="card" style={{ margin: 0 }} key={p.code}>
                      <div className="plan">{p.name}</div><h2>{p.price}</h2>
                      {p.perks.map((x) => <div className="chk" key={x}>• {x}</div>)}
                      <button className="btn" style={{ marginTop: 12 }} disabled={cur} onClick={() => !cur && startCheckout(p.code)}>{cur ? 'Current plan' : 'Upgrade'}</button>
                    </div>
                  );
                })}
              </div>
              <p className="chk" style={{ marginTop: 12, marginBottom: 0 }}>Payments are processed securely by Stripe. Automated analysis for information only, not investment advice.</p>
            </div>
          </div>
        )}

        {view === 'admin' && isAdmin && <Admin data={adminData} />}

        <div className="foot">Automated analysis for information only — <strong>not investment advice</strong>; predictions are not guarantees and trading involves risk of loss. Headlines link to publishers. <a href="/legal/disclaimer">Disclaimer</a> · <a href="/legal/terms">Terms</a> · <a href="/legal/privacy">Privacy</a></div>
      </div>

      {dlg && <WidgetDialog dlg={dlg} setDlg={setDlg} sources={sources} onSave={saveWidget} />}
      <div id="toasts" aria-live="polite">
        {toasts.map((t) => (
          <div className="toast" key={t.id}><div className="tt"><a href={safe(t.url || '#')} target="_blank" rel="noopener noreferrer">{t.title || 'New alert'}</a></div><div className="ts">{(t.source || '') + (t.category ? ` · ${t.category}` : '')}</div></div>
        ))}
      </div>
    </div>
  );
}

// ---------- sub-components ----------
function Row({ i, hot, fresh, tickers }) {
  const arr = i.score > 0.15 ? 'up' : i.score < -0.15 ? 'down' : '';
  return (
    <div className={`r${hot ? ' hot' : ''}${fresh ? ' new' : ''}`}>
      <span className="t">{hhmm(tsOf(i))}</span>
      <div>
        <a href={safe(i.url)} target="_blank" rel="noopener noreferrer">{i.title}</a>
        <span className="src">{(i.impact ? '● ' : '') + i.source_name + ' · ' + i.category}</span>
        {tickers?.length ? <span className="tickers">{tickers.slice(0, 4).map((t) => <span className="tk" key={t.ticker}>${t.ticker}</span>)}</span> : null}
      </div>
      <span className={`ar ${arr}`}>{i.score > 0.15 ? '↑' : i.score < -0.15 ? '↓' : ''}</span>
    </div>
  );
}

function WidgetDialog({ dlg, setDlg, sources, onSave }) {
  return (
    <div className="mdl-bg" onMouseDown={(e) => { if (e.target === e.currentTarget) setDlg(null); }}>
      <div className="mdl" role="dialog" aria-modal="true">
        <h2 style={{ margin: '0 0 4px', fontSize: 16 }}>{dlg.editingId ? 'Edit widget' : 'Add widget'}</h2>
        <label>Name</label>
        <input type="text" maxLength={30} value={dlg.title} onChange={(e) => setDlg({ ...dlg, title: e.target.value })} />
        <label>Category</label>
        <select value={dlg.cat} onChange={(e) => setDlg({ ...dlg, cat: e.target.value })}>
          <option value="">All categories</option>{CATS.map((c) => <option key={c} value={c}>{c}</option>)}
        </select>
        <label>Source</label>
        <select value={dlg.src} onChange={(e) => setDlg({ ...dlg, src: e.target.value })}>
          <option value="">All sources</option>{sources.map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
        <label>Headline contains</label>
        <input type="text" maxLength={30} placeholder="optional" value={dlg.kw} onChange={(e) => setDlg({ ...dlg, kw: e.target.value })} />
        <div className="row" style={{ marginTop: 16, justifyContent: 'flex-end' }}>
          <button className="btn g" onClick={() => setDlg(null)}>Cancel</button>
          <button className="btn" onClick={onSave}>Save</button>
        </div>
      </div>
    </div>
  );
}

function Watchlists({ items, kws, rules, setRules, ent, sb, addKw, removeKw, squawkAll, setSquawkAll, entByItem }) {
  const [kwInput, setKwInput] = useState('');
  const [arTerm, setArTerm] = useState('');
  const [arScore, setArScore] = useState('0');
  const [arChannels, setArChannels] = useState(['in_app']);
  const allowed = ent.channels || ['in_app'];
  const hits = items.filter((i) => matchKw(kws, i.title)).slice(0, 60);

  const addRule = async () => {
    const term = arTerm.trim().slice(0, 40); if (!term) return;
    if (!arChannels.length) { alert('Pick at least one channel.'); return; }
    const { data, error } = await sb.from('alert_rules').insert({ term, min_abs_score: Number(arScore), channels: arChannels, enabled: true }).select().single();
    if (error) { alert('Could not add rule.'); return; }
    setRules((r) => [...r, data]); setArTerm('');
  };
  const removeRule = async (r) => { setRules((x) => x.filter((y) => y.id !== r.id)); await sb.from('alert_rules').delete().eq('id', r.id); };
  const saveQuiet = async (qs, qe) => { const { data: { user } } = await sb.auth.getUser(); await sb.from('notification_prefs').upsert({ user_id: user.id, quiet_start: qs, quiet_end: qe }); alert('Quiet hours saved.'); };

  return (
    <div className="page">
      <div className="card"><h2>Alert keywords</h2>
        <div className="row">
          <input type="text" placeholder="Add a ticker, company or topic, e.g. NVDA, Powell, oil" aria-label="Add keyword"
            value={kwInput} onChange={(e) => setKwInput(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { addKw(kwInput); setKwInput(''); } }} />
          <button className="btn" onClick={() => { addKw(kwInput); setKwInput(''); }}>Add</button>
        </div>
        <div>{kws.map((w) => <span className="kw" key={w.id}>{w.term}<button aria-label={`Remove ${w.term}`} onClick={() => removeKw(w)}>×</button></span>)}</div>
        <label className="chk"><input type="checkbox" checked={squawkAll} onChange={(e) => setSquawkAll(e.target.checked)} /> Squawk reads every new headline, not just highlighted ones</label>
      </div>
      <div className="card"><h2>Headlines matching your keywords</h2>
        {!hits.length && <div className="empty">No matches yet.</div>}
        {hits.map((i) => <Row key={i.id} i={i} hot fresh={false} tickers={entByItem[i.id]} />)}
      </div>
      <div className="card"><h2>Alert rules</h2>
        <p className="chk" style={{ margin: '0 0 8px' }}>Get notified when a headline matches a term or ticker. Channels depend on your plan.</p>
        <div className="row">
          <input type="text" placeholder="Term or $TICKER, e.g. Powell or NVDA" aria-label="Alert term" value={arTerm} onChange={(e) => setArTerm(e.target.value)} />
          <select aria-label="Minimum strength" style={{ maxWidth: 150 }} value={arScore} onChange={(e) => setArScore(e.target.value)}>
            <option value="0">Any strength</option><option value="0.3">Weak+ (0.3)</option><option value="0.5">Strong (0.5)</option><option value="0.7">Very strong (0.7)</option>
          </select>
        </div>
        <div className="chk" style={{ flexWrap: 'wrap' }}>
          {CHANNELS.map(([val, label]) => {
            const ok = allowed.includes(val); const on = arChannels.includes(val);
            return (
              <label className="chk" style={{ margin: '8px 14px 0 0' }} key={val}>
                <input type="checkbox" disabled={!ok} checked={ok && on} onChange={(e) => setArChannels((c) => e.target.checked ? [...c, val] : c.filter((x) => x !== val))} /> {label}{!ok && <span className="lock">🔒</span>}
              </label>
            );
          })}
        </div>
        <div className="row" style={{ marginTop: 10, justifyContent: 'flex-end' }}><button className="btn" onClick={addRule}>Add rule</button></div>
        <div style={{ marginTop: 12 }}>
          {!rules.length && <div className="empty">No alert rules yet.</div>}
          {rules.map((r) => <div className="arule" key={r.id}><span className="term">{r.term}</span><span className="chs">≥{r.min_abs_score} · {(r.channels || []).join(', ')}</span><button aria-label={`Remove rule ${r.term}`} onClick={() => removeRule(r)}>×</button></div>)}
        </div>
      </div>
      <QuietHours sb={sb} onSave={saveQuiet} />
    </div>
  );
}

function QuietHours({ sb, onSave }) {
  const [qs, setQs] = useState(''); const [qe, setQe] = useState('');
  useEffect(() => { (async () => {
    const { data: { user } } = await sb.auth.getUser(); if (!user) return;
    const { data } = await sb.from('notification_prefs').select('quiet_start,quiet_end').eq('user_id', user.id).maybeSingle();
    if (data) { setQs(data.quiet_start ?? ''); setQe(data.quiet_end ?? ''); }
  })(); }, [sb]);
  const opts = ['', ...Array.from({ length: 24 }, (_, h) => String(h))];
  return (
    <div className="card"><h2>Quiet hours</h2>
      <p className="chk" style={{ margin: '0 0 8px' }}>Pause email/push alerts during these local hours (in-app squawk still works).</p>
      <div className="row">
        <select aria-label="Quiet start" value={qs} onChange={(e) => setQs(e.target.value)}>{opts.map((h) => <option key={h || 'x'} value={h}>{h === '' ? '—' : `${h.padStart(2, '0')}:00`}</option>)}</select>
        <select aria-label="Quiet end" value={qe} onChange={(e) => setQe(e.target.value)}>{opts.map((h) => <option key={h || 'x'} value={h}>{h === '' ? '—' : `${h.padStart(2, '0')}:00`}</option>)}</select>
        <button className="btn g" onClick={() => onSave(qs === '' ? null : Number(qs), qe === '' ? null : Number(qe))}>Save</button>
      </div>
    </div>
  );
}

function Admin({ data }) {
  if (!data) return <div className="page"><div className="card">Loading…</div></div>;
  if (data.error) return <div className="page"><div className="card">{data.error}</div></div>;
  const { rev, us, src } = data;
  const byPlan = us?.by_plan ? Object.entries(us.by_plan).map(([k, v]) => `${k}: ${v}`).join(' · ') : '—';
  return (
    <div className="page">
      <div className="card"><h2>Revenue (last 30 days)</h2>
        <div className="chk" style={{ margin: 0 }}>{rev ? `Paid: ${money(rev.paid_30d_cents)} (${rev.paid_count_30d} payments) · Failed: ${rev.failed_30d} · Active subs: ${rev.active_subscriptions}` : '—'}</div>
      </div>
      <div className="card"><h2>Users</h2>
        <div className="chk" style={{ margin: 0 }}>{us ? `Total: ${us.total_users} · New (7d): ${us.new_7d} · By plan: ${byPlan}` : '—'}</div>
      </div>
      <div className="card"><h2>Source health</h2>
        {!src?.length && <div className="empty">No sources.</div>}
        {src?.map((row) => (
          <div className="arule" key={row.name}>
            <span style={{ color: row.stale ? 'var(--down)' : 'var(--up)' }}>{row.stale ? '● ' : '○ '}</span>
            <span className="term">{row.name}</span>
            <span className="chs">{`${row.kind || '—'} · last ok ${row.minutes_since_success == null ? 'never' : Math.round(row.minutes_since_success) + 'm ago'} · fails ${row.failure_count}`}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ---------- Auth gate ----------
function Gate({ sb }) {
  const [signup, setSignup] = useState(false);
  const [email, setEmail] = useState(''); const [pass, setPass] = useState('');
  const [consent, setConsent] = useState(false);
  const [err, setErr] = useState(''); const [errColor, setErrColor] = useState('var(--down)');
  const [busy, setBusy] = useState(false);
  const tsToken = useRef(null); const tsWidget = useRef(null); const tsBox = useRef(null);
  const siteKey = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY;

  useEffect(() => {
    if (!siteKey) return;
    let tries = 0;
    const id = setInterval(() => {
      tries += 1;
      if (window.turnstile && tsBox.current && tsWidget.current === null) {
        try { tsWidget.current = window.turnstile.render(tsBox.current, { sitekey: siteKey, callback: (t) => { tsToken.current = t; }, 'expired-callback': () => { tsToken.current = null; }, 'error-callback': () => { tsToken.current = null; } }); } catch (e) { /* ignore */ }
        clearInterval(id);
      }
      if (tries > 40) clearInterval(id);
    }, 150);
    return () => clearInterval(id);
  }, [siteKey]);

  const resetTs = () => { tsToken.current = null; if (tsWidget.current !== null && window.turnstile) { try { window.turnstile.reset(tsWidget.current); } catch (e) { /* ignore */ } } };

  const submit = async () => {
    setErr('');
    if (!email || !pass) { setErr('Enter email and password.'); return; }
    if (signup && pass.length < 10) { setErr('Password must be at least 10 characters.'); return; }
    if (signup && !consent) { setErr('Please accept the Terms and Privacy Policy.'); return; }
    if (siteKey && !tsToken.current) { setErr('Please complete the challenge.'); return; }
    const opts = siteKey ? { captchaToken: tsToken.current } : undefined;
    setBusy(true);
    try {
      if (signup) {
        const { error } = await sb.auth.signUp({ email, password: pass, options: opts });
        if (error) throw error;
        setErrColor('var(--muted)'); setErr('Check your email to verify, then log in.'); setSignup(false);
      } else {
        const { error } = await sb.auth.signInWithPassword({ email, password: pass, options: opts });
        if (error) throw error;
      }
    } catch (e) { setErrColor('var(--down)'); setErr(signup ? (e.message || 'Could not sign up.') : 'Invalid email or password.'); }
    resetTs(); setBusy(false);
  };

  return (
    <div className="gate">
      <div className="card">
        <h1>Squawkwire</h1>
        <p className="sub">{signup ? 'Create your account' : 'Log in to your terminal'}</p>
        <label>Email</label>
        <input type="email" autoComplete="email" placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} />
        <label>Password {signup && <span style={{ color: 'var(--muted)' }}>(min 10 characters)</span>}</label>
        <input type="password" autoComplete={signup ? 'new-password' : 'current-password'} placeholder="••••••••" value={pass} onChange={(e) => setPass(e.target.value)} />
        <div ref={tsBox} style={{ marginTop: 10 }} />
        {signup && <label className="chk" style={{ fontSize: 12 }}><input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} /> I agree to the <a href="/legal/terms" target="_blank" rel="noopener noreferrer">Terms</a> and <a href="/legal/privacy" target="_blank" rel="noopener noreferrer">Privacy Policy</a></label>}
        <div className="err" style={{ color: errColor }}>{err}</div>
        <div className="row" style={{ marginTop: 6 }}><button className="btn" style={{ flex: 1 }} disabled={busy} onClick={submit}>{signup ? 'Create account' : 'Log in'}</button></div>
        <p className="chk" style={{ marginTop: 14, justifyContent: 'center' }}>
          <span className="link" onClick={() => { setSignup((s) => !s); setErr(''); }}>{signup ? 'Have an account? Log in' : 'Need an account? Sign up'}</span>
        </p>
      </div>
    </div>
  );
}
