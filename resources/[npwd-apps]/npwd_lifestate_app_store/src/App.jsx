import React from 'react'
import { DEFAULT_ACCENT, accents, icons } from './icons'

// The store is a view over server state only. It never decides eligibility, and
// it never remembers installs: every action returns the fresh server payload.
//
// Layout notes (NPWD renders every app inside the phone shell with the bottom
// navigation below it):
//   * flex:1 / maxHeight:100% / overflow:auto keeps the store inside its own
//     container, so the bottom navigation is never covered. No 100vh anywhere.
//   * The grid is the storefront; tapping a tile opens a small detail view with
//     the actions, so the home grid stays compact as the catalog grows.
//
// Cached list so reopening the phone shows content instantly instead of a
// permanent loading state (the same approach as the Ojol apps).
let cachedStore = null

const nui = (endpoint, body) =>
  fetch(`https://npwd_lifestate_app_store/${endpoint}`, body
    ? {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      }
    : undefined
  ).then((response) => response.json())

const REASON_MESSAGES = {
  driver_only: 'Hanya Mitra LAJU terdaftar yang bisa memasang aplikasi ini.',
  invalid_character: 'Karakter tidak valid.',
  too_fast: 'Terlalu cepat. Coba lagi sebentar.',
  database_error: 'Gagal menyimpan perubahan. Coba lagi.',
  unknown_app: 'Aplikasi tidak dikenal.',
  not_eligible: 'Kamu belum memenuhi syarat untuk aplikasi ini.',
  callback_failed: 'Gagal menghubungi server.'
}

function AppIcon({ id, size }) {
  const Icon = icons[id] || icons.__default
  return <Icon width={size} height={size} />
}

const accentFor = (entry) => accents[entry.id] || DEFAULT_ACCENT

function StateDot({ entry }) {
  if (!entry.eligible) {
    return <div style={{ ...styles.tileDot, ...styles.tileDotLocked }}>!</div>
  }

  if (entry.installed) {
    return <div style={{ ...styles.tileDot, ...styles.tileDotInstalled }} />
  }

  return null
}

function Grid({ apps, onOpen }) {
  return (
    <div style={styles.grid}>
      {apps.map((entry) => (
        <button
          key={entry.id}
          type="button"
          style={styles.tile}
          onClick={() => onOpen(entry.id)}
        >
          <div
            style={{
              ...styles.tileIcon,
              background: accentFor(entry),
              opacity: entry.eligible ? 1 : 0.45
            }}
          >
            <AppIcon id={entry.id} size={30} />
          </div>
          <div style={styles.tileName}>{entry.name}</div>
          <StateDot entry={entry} />
        </button>
      ))}
    </div>
  )
}

function Detail({ entry, busy, onBack, onInstall, onUninstall }) {
  return (
    <div>
      <button type="button" style={styles.back} onClick={onBack}>
        &#8592; Kembali
      </button>

      <div style={styles.detailHeader}>
        <div
          style={{
            ...styles.detailIcon,
            background: accentFor(entry),
            opacity: entry.eligible ? 1 : 0.45
          }}
        >
          <AppIcon id={entry.id} size={38} />
        </div>
        <div style={styles.detailText}>
          <div style={styles.detailName}>{entry.name}</div>
          <div style={styles.detailState}>
            {!entry.eligible
              ? entry.lockLabel || 'Tidak tersedia'
              : entry.installed
                ? 'Terpasang'
                : 'Belum terpasang'}
          </div>
        </div>
      </div>

      <div style={styles.detailDescription}>{entry.description}</div>

      {!entry.eligible && (
        <button style={{ ...styles.button, ...styles.disabledButton }} disabled>
          TIDAK TERSEDIA
        </button>
      )}

      {entry.eligible && entry.installed && (
        <div>
          <button
            style={{ ...styles.button, ...styles.uninstallButton }}
            disabled={busy}
            onClick={() => onUninstall(entry.id)}
          >
            {busy ? 'MEMPROSES...' : 'UNINSTALL'}
          </button>
          <div style={styles.detailHint}>
            Buka aplikasinya dari layar utama HP.
          </div>
        </div>
      )}

      {entry.eligible && !entry.installed && (
        <button
          style={{ ...styles.button, ...styles.installButton }}
          disabled={busy}
          onClick={() => onInstall(entry.id)}
        >
          {busy ? 'MEMPROSES...' : 'INSTALL'}
        </button>
      )}
    </div>
  )
}

function App() {
  const [store, setStore] = React.useState(cachedStore)
  const [loading, setLoading] = React.useState(cachedStore === null)
  const [busyApp, setBusyApp] = React.useState(null)
  const [selected, setSelected] = React.useState(null)
  const [error, setError] = React.useState('')

  const applyStore = (data) => {
    if (!data) return
    cachedStore = data
    setStore(data)
  }

  const load = () => {
    setError('')

    return nui('npwd:lifestate_app_store:list')
      .then((response) => {
        if (response.status !== 'ok' || !response.data) {
          setError(REASON_MESSAGES.callback_failed)
          return
        }

        if (response.data.success === false) {
          setError(REASON_MESSAGES[response.data.reason] || REASON_MESSAGES.callback_failed)
          return
        }

        applyStore(response.data.data)
      })
      .catch(() => setError(REASON_MESSAGES.callback_failed))
      .finally(() => setLoading(false))
  }

  React.useEffect(() => {
    load()
  }, [])

  const act = (appId, action) => {
    setBusyApp(appId)
    setError('')

    return nui(`npwd:lifestate_app_store:${action}`, { appId })
      .then((response) => {
        if (response.status !== 'ok' || !response.data) {
          setError(REASON_MESSAGES.callback_failed)
          return
        }

        if (response.data.success === false) {
          setError(REASON_MESSAGES[response.data.reason] || REASON_MESSAGES.callback_failed)
          return
        }

        applyStore(response.data.data)
      })
      .catch(() => setError(REASON_MESSAGES.callback_failed))
      .finally(() => setBusyApp(null))
  }

  const apps = store && Array.isArray(store.apps) ? store.apps : null
  const selectedEntry =
    apps && selected ? apps.find((entry) => entry.id === selected) || null : null

  return (
    <div style={styles.container}>
      <div style={styles.app}>
        <div style={styles.brandBar} />
        <div style={styles.eyebrow}>LIFESTATE</div>
        <div style={styles.title}>APP STORE</div>
        <div style={styles.subtitle}>Aplikasi resmi untuk HP kamu</div>

        {loading && !apps && <div style={styles.hint}>Memuat...</div>}

        {!loading && !apps && (
          <div>
            <div style={styles.hint}>Daftar aplikasi tidak bisa dimuat.</div>
            <button style={{ ...styles.button, ...styles.installButton }} onClick={load}>
              COBA LAGI
            </button>
          </div>
        )}

        {apps && apps.length === 0 && (
          <div style={styles.hint}>Belum ada aplikasi yang tersedia.</div>
        )}

        {apps && !selectedEntry && <Grid apps={apps} onOpen={setSelected} />}

        {apps && selectedEntry && (
          <Detail
            entry={selectedEntry}
            busy={busyApp === selectedEntry.id}
            onBack={() => setSelected(null)}
            onInstall={(appId) => act(appId, 'install')}
            onUninstall={(appId) => act(appId, 'uninstall')}
          />
        )}

        {error && <div style={styles.error}>{error}</div>}
      </div>
    </div>
  )
}

const styles = {
  container: {
    background: '#0B0D12',
    color: '#ffffff',
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
    width: '100%',
    flex: 1,
    maxHeight: '100%',
    overflow: 'auto',
    boxSizing: 'border-box',
    display: 'flex',
    alignItems: 'flex-start',
    justifyContent: 'center',
    padding: '16px'
  },
  app: {
    width: '100%',
    maxWidth: '380px',
    background: '#12151C',
    border: '1px solid #1E232D',
    borderRadius: '16px',
    padding: '20px',
    boxSizing: 'border-box',
    boxShadow: '0 8px 32px rgba(0,0,0,0.4)'
  },
  brandBar: {
    width: '28px',
    height: '3px',
    borderRadius: '2px',
    background: '#D71920',
    marginBottom: '12px'
  },
  eyebrow: {
    color: '#6F7885',
    fontSize: '11px',
    fontWeight: '700',
    letterSpacing: '3px',
    marginBottom: '2px'
  },
  title: {
    fontSize: '20px',
    fontWeight: '800',
    letterSpacing: '1px'
  },
  subtitle: {
    color: '#9AA3AF',
    fontSize: '12px',
    marginTop: '4px',
    marginBottom: '18px'
  },
  hint: {
    color: '#9AA3AF',
    fontSize: '13px',
    marginBottom: '14px'
  },
  grid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(3, 1fr)',
    gap: '12px'
  },
  tile: {
    position: 'relative',
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: '8px',
    padding: '14px 6px 12px',
    minHeight: '118px',
    boxSizing: 'border-box',
    background: '#181C24',
    borderWidth: '1px',
    borderStyle: 'solid',
    borderColor: '#292F3A',
    borderRadius: '14px',
    cursor: 'pointer',
    color: '#ffffff',
    font: 'inherit'
  },
  tileIcon: {
    width: '56px',
    height: '56px',
    borderRadius: '16px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    color: '#ffffff'
  },
  tileName: {
    fontSize: '12px',
    fontWeight: '600',
    lineHeight: '14px',
    textAlign: 'center',
    wordBreak: 'break-word'
  },
  tileDot: {
    position: 'absolute',
    top: '10px',
    right: '10px',
    width: '10px',
    height: '10px',
    borderRadius: '6px',
    boxSizing: 'border-box'
  },
  tileDotInstalled: {
    background: '#22c55e',
    border: '2px solid #12151C'
  },
  tileDotLocked: {
    background: '#1E232D',
    border: '1px solid #f59e0b',
    color: '#f59e0b',
    fontSize: '9px',
    lineHeight: '10px',
    fontWeight: '700',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center'
  },
  back: {
    background: 'none',
    border: 'none',
    color: '#9AA3AF',
    fontSize: '12px',
    fontWeight: '600',
    padding: '0 0 14px 0',
    cursor: 'pointer',
    font: 'inherit'
  },
  detailHeader: {
    display: 'flex',
    alignItems: 'center',
    gap: '16px',
    marginBottom: '16px'
  },
  detailIcon: {
    width: '76px',
    height: '76px',
    flexShrink: 0,
    borderRadius: '20px',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    color: '#ffffff'
  },
  detailText: {
    flex: 1,
    minWidth: 0
  },
  detailName: {
    fontSize: '19px',
    fontWeight: '800',
    letterSpacing: '0.5px'
  },
  detailState: {
    color: '#9AA3AF',
    fontSize: '11px',
    fontWeight: '700',
    letterSpacing: '1px',
    textTransform: 'uppercase',
    marginTop: '4px'
  },
  detailDescription: {
    background: '#181C24',
    border: '1px solid #292F3A',
    borderRadius: '12px',
    padding: '14px',
    color: '#c9d3cc',
    fontSize: '13px',
    lineHeight: '20px',
    marginBottom: '16px'
  },
  detailHint: {
    color: '#6F7885',
    fontSize: '11px',
    marginTop: '8px',
    textAlign: 'center'
  },
  button: {
    width: '100%',
    padding: '13px',
    border: 'none',
    borderRadius: '11px',
    fontSize: '14px',
    fontWeight: '800',
    letterSpacing: '1px',
    cursor: 'pointer'
  },
  installButton: {
    background: '#D71920',
    color: '#FFFFFF'
  },
  uninstallButton: {
    background: '#2A1115',
    borderWidth: '1px',
    borderStyle: 'solid',
    borderColor: '#D71920',
    color: '#ffffff'
  },
  disabledButton: {
    background: '#181C24',
    color: '#6F7885',
    cursor: 'not-allowed'
  },
  error: {
    color: '#ef4444',
    fontSize: '13px',
    marginTop: '12px'
  }
}

export default App
