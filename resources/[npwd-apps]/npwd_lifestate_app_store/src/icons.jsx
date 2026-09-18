import React from 'react'

// Real icons, copied verbatim from NPWD's own bundles and from each Ojol app's
// NPWD `config.jsx`, so the store and the home screen show the same glyph.
// Presentation only - nothing here decides visibility.
//
// Adding an app to the server catalog means adding it here too, otherwise it
// falls back to the generic store glyph.
//
// NPWD mixes two icon styles, so both are supported: the MUI-style filled glyphs
// (Ojol, Matchmaker, IRC, Marketplace) and the Lucide-style stroked glyphs
// (Social), which is how NPWD itself renders them.

const svg = (props, paths) =>
  React.createElement('svg', {
    ...props,
    viewBox: '0 0 24 24',
    xmlns: 'http://www.w3.org/2000/svg'
  }, paths.map((d, index) => React.createElement('path', { d, key: index })))

const filled = (...paths) => (props) =>
  svg({ ...props, fill: 'currentColor' }, paths)

const stroked = (...paths) => (props) =>
  svg({
    ...props,
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 2,
    strokeLinecap: 'round',
    strokeLinejoin: 'round'
  }, paths)

// Ojol Driver (npwd_lifestate_ojol)
const driver = filled('M18.92 6.01C18.72 5.42 18.16 5 17.5 5h-11c-.83 0-1.5.67-1.5 1.5S5.67 8 6.5 8h1.84L6 13l-2 1 1 1 2-1v1c0 .83.67 1.5 1.5 1.5h1c.83 0 1.5-.67 1.5-1.5v-1h4v1c0 .83.67 1.5 1.5 1.5h1c.83 0 1.5-.67 1.5-1.5v-1l1-1-1-1-2 1-1.16-3.99c.34-.29.56-.7.56-1.15 0-.83-.67-1.5-1.5-1.5zm-1.5 8.5h-1v-3h1v3zm-10-6h1.5v3h-1.5v-3zm11.5 6.5c-.55 0-1-.45-1-1s.45-1 1-1 1 .45 1 1-.45 1-1 1z')

// Ojol Customer (npwd_lifestate_ojol_customer)
const customer = filled('M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5A2.5 2.5 0 1 1 12 6.5a2.5 2.5 0 0 1 0 5z')

// Generic store glyph (also the store's own icon).
const store = filled('M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z')

// NPWD built-in MATCH -> "Favorite" (icons/material/svg/MATCH.tsx)
const matchmaker = filled('m12 21.35-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z')

// NPWD built-in DARKCHAT (shown as "IRC") -> "Forum"
const irc = filled('M21 6h-2v9H6v2c0 .55.45 1 1 1h11l4 4V7c0-.55-.45-1-1-1zm-4 6V3c0-.55-.45-1-1-1H3c-.55 0-1 .45-1 1v14l4-4h10c.55 0 1-.45 1-1z')

// NPWD built-in TWITTER (shown as "Life Invader"/Social) -> Lucide "Bird"
const social = stroked(
  'M16 7h.01',
  'M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20',
  'm20 7 2 .5-2 .5',
  'M10 18v3',
  'M14 17.75V21',
  'M7 18a6 6 0 0 0 3.84-10.61'
)

// NPWD built-in MARKETPLACE -> "MonetizationOn"
const marketplace = filled('M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1.41 16.09V20h-2.67v-1.93c-1.71-.36-3.16-1.46-3.27-3.4h1.96c.1 1.05.82 1.87 2.65 1.87 1.96 0 2.4-.98 2.4-1.59 0-.83-.44-1.61-2.67-2.14-2.48-.6-4.18-1.62-4.18-3.67 0-1.72 1.39-2.84 3.11-3.21V4h2.67v1.95c1.86.45 2.79 1.86 2.85 3.39H14.3c-.05-1.11-.64-1.87-2.22-1.87-1.5 0-2.4.68-2.4 1.64 0 .84.65 1.39 2.67 1.91s4.18 1.39 4.18 3.91c-.01 1.83-1.38 2.83-3.12 3.16z')

export const icons = {
  npwd_lifestate_ojol: driver,
  npwd_lifestate_ojol_customer: customer,
  npwd_lifestate_app_store: store,
  MATCH: matchmaker,
  DARKCHAT: irc,
  TWITTER: social,
  MARKETPLACE: marketplace,
  __default: store
}

// Tile accent colours. MATCH, TWITTER and DARKCHAT use NPWD's own registry
// `backgroundColor`; MARKETPLACE's comes from a palette object that is not
// statically resolvable in the bundle, so it uses a close match.
export const accents = {
  npwd_lifestate_ojol: '#333333',
  npwd_lifestate_ojol_customer: '#16201b',
  npwd_lifestate_app_store: '#1b2440',
  MATCH: '#FE3B73',
  DARKCHAT: '#212121',
  TWITTER: '#0ea5e9',
  MARKETPLACE: '#14b8a6'
}

export const DEFAULT_ACCENT = '#1b2440'
