import React from 'react'
import App from './App'

const path = '/npwd_lifestate_app_store'

// Lifestate App Store mark: an "L" built from three rounded app tiles - the
// left column plus the bottom-right foot cell in LAJU red. One concept: the
// store is where Lifestate's apps live. Bold 7-unit cells read at small size;
// explicit fills (not currentColor) so the home tile and the store tile
// render exactly the same ink.
const STORE_CELL_A = { x: 4, y: 4 }
const STORE_CELL_B = { x: 4, y: 13 }
const STORE_CELL_C = { x: 13, y: 13 }
const CELL_SIZE = 7
const CELL_RX = 2

const LajuStoreMark = () => (
  <React.Fragment>
    <rect x={STORE_CELL_A.x} y={STORE_CELL_A.y} width={CELL_SIZE} height={CELL_SIZE} rx={CELL_RX} fill="#FFFFFF" />
    <rect x={STORE_CELL_B.x} y={STORE_CELL_B.y} width={CELL_SIZE} height={CELL_SIZE} rx={CELL_RX} fill="#FFFFFF" />
    <rect x={STORE_CELL_C.x} y={STORE_CELL_C.y} width={CELL_SIZE} height={CELL_SIZE} rx={CELL_RX} fill="#D71920" />
  </React.Fragment>
)

// Expanded home-screen viewBox (internal padding) so the mark occupies the
// same fraction of the NPWD home tile as it does of the App Store tile.
// Geometry untouched - verified side-by-side against the store version.
const HOME_VIEWBOX = '-4 -4 32 32'

const Icon = (props) => (
  <svg
    {...props}
    viewBox={HOME_VIEWBOX}
    xmlns="http://www.w3.org/2000/svg"
  >
    <LajuStoreMark />
  </svg>
)

// Notifications keep the full-bleed single-ink geometry: they render much
// smaller and must stay maximally legible rather than match tile padding.
const NotificationIcon = (props) => (
  <svg
    {...props}
    viewBox="0 0 24 24"
    fill="currentColor"
    xmlns="http://www.w3.org/2000/svg"
  >
    <rect x={STORE_CELL_A.x} y={STORE_CELL_A.y} width={CELL_SIZE} height={CELL_SIZE} rx={CELL_RX} />
    <rect x={STORE_CELL_B.x} y={STORE_CELL_B.y} width={CELL_SIZE} height={CELL_SIZE} rx={CELL_RX} />
    <rect x={STORE_CELL_C.x} y={STORE_CELL_C.y} width={CELL_SIZE} height={CELL_SIZE} rx={CELL_RX} />
  </svg>
)

// NPWD calls this function on the default export, so ./config MUST be callable.
const config = () => ({
  id: 'npwd_lifestate_app_store',
  nameLocale: 'Lifestate App Store',
  color: '#ffffff',
  backgroundColor: '#1b2440',
  path,
  icon: Icon,
  app: App,
  notificationIcon: NotificationIcon
})

export default config
export { path }
