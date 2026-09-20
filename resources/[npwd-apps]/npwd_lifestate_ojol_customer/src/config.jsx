import React from 'react'
import App from './App'

const path = '/npwd_lifestate_ojol_customer'

// LAJU brand mark: a bold geometric "L" whose foot ends in a forward arrow.
// Two polygons, no cuts, strong silhouette - readable down to ~24 px.
// Monochrome: rendered in `currentColor` so NPWD/store tiles decide the ink.
//
// The home-screen Icon uses an expanded viewBox (-3 -3 30 30) as internal
// padding: NPWD renders the home glyph larger inside its tile than the App
// Store does, so without this the mark looks oversized next to the store
// version. Geometry is untouched - verified side-by-side against the store
// tile that the mark occupies the same fraction of the tile.
const LAJU_STEM = '3,3 8,3 8,15 3,15'
const LAJU_FOOT = '3,15 13,15 18.5,17.5 13,20 3,20'
const HOME_VIEWBOX = '-5 -5 34 34'

const Icon = (props) => (
  <svg
    {...props}
    viewBox={HOME_VIEWBOX}
    fill="currentColor"
    xmlns="http://www.w3.org/2000/svg"
  >
    <polygon points={LAJU_STEM} />
    <polygon points={LAJU_FOOT} />
  </svg>
)

// Notifications keep the full-bleed geometry: they render much smaller and
// must stay maximally legible rather than match tile padding.
const NotificationIcon = (props) => (
  <svg
    {...props}
    viewBox="0 0 24 24"
    fill="currentColor"
    xmlns="http://www.w3.org/2000/svg"
  >
    <polygon points={LAJU_STEM} />
    <polygon points={LAJU_FOOT} />
  </svg>
)

const config = () => ({
  id: 'npwd_lifestate_ojol_customer',
  nameLocale: 'LAJU',
  color: '#FFFFFF',
  backgroundColor: '#D71920',
  path,
  icon: Icon,
  app: App,
  notificationIcon: NotificationIcon
})

export default config
export { path }
