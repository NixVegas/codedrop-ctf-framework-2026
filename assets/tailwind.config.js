// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration

const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/ctf_server_web.ex",
    "../lib/ctf_server_web/**/*.*ex"
  ],
  theme: {
    extend: {
      // De-designed (#106): after the strip-down sweep, NONE of these custom
      // ramps are referenced by the app — every page renders in stock zinc.
      // They're kept defined so the visual design pass has the 2026 colors on
      // hand to pick from; delete whichever ones it doesn't adopt.
      //
      // A `white` ramp used to live here too. It was removed, not just
      // unreferenced: defining `white` as an object SHADOWS Tailwind's built-in
      // `white`, so `text-white` / `bg-white` compiled to nothing at all — the
      // primary button's label color had silently been a no-op. Don't
      // reintroduce a ramp named `white` (or `black`).
      colors: {
        brand: "#FD4F00",
        green: {
          50: '#eff5f0',
          100: '#ddeedf',
          200: '#b3e6b8',
          300: '#7fe68b',
          400: '#4be75e',
          500: '#0ea11e',
          600: '#0ea420',
          700: '#0a7517',
          800: '#094310',
          900: '#082b0c',
          950: '#051407'
        },
        darkBlue: {
          50: '#f0f0f4',
          100: '#e0e1eb',
          200: '#bbbddd',
          300: '#9195d4',
          400: '#666dcc',
          500: '#454dc9',
          600: '#3139aa',
          700: '#262c82',
          800: '#1d2158',
          900: '#131530',
          950: '#0c0e1c'
        },
        lightBlue: {
          50: '#f0f3f4',
          100: '#e0e9eb',
          200: '#bad6de',
          300: '#8fc5d6',
          400: '#64b5ce',
          500: '#6ec0d8',
          600: '#46aece',
          700: '#2f93b1',
          800: '#2a6f84',
          900: '#214c59',
          950: '#1d3b44'
        },
        yellow: {
          50: '#f5f4f0',
          100: '#ece9df',
          200: '#dfd6b9',
          300: '#dac78b',
          400: '#d4b95e',
          500: '#d2ad33',
          600: '#ab8c26',
          700: '#826a1c',
          800: '#554616',
          900: '#2a240e',
          950: '#161308'
        },
        orange: {
          50: '#f6f1ef',
          100: '#eee3dd',
          200: '#e7c4b1',
          300: '#e8a27d',
          400: '#ea8148',
          500: '#f06012',
          600: '#c54d0d',
          700: '#953a09',
          800: '#60290b',
          900: '#301608',
          950: '#190c06'
        },
        fuchsia: {
          50: '#f5eff6',
          100: '#ecddee',
          200: '#dfb1e7',
          300: '#d97ee7',
          400: '#d34ae8',
          500: '#db44f1',
          600: '#d117ee',
          700: '#aa0fc2',
          800: '#7c128c',
          900: '#51115a',
          950: '#3b1041'
        }
      }
    },
  },
  plugins: [
    require("@tailwindcss/forms"),
    require("@tailwindcss/typography"),
    // Allows prefixing tailwind classes with LiveView classes to add rules
    // only when LiveView classes are applied, for example:
    //
    //     <div class="phx-click-loading:animate-ping">
    //
    plugin(({ addVariant }) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({ addVariant }) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({ addVariant }) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),

    // Embeds Heroicons (https://heroicons.com) into your app.css bundle
    // See your `CoreComponents.icon/1` for more information.
    //
    plugin(function ({ matchComponents, theme }) {
      let iconsDir = path.join(__dirname, "../deps/heroicons/optimized")
      let values = {}
      let icons = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"],
        ["-micro", "/16/solid"]
      ]
      icons.forEach(([suffix, dir]) => {
        fs.readdirSync(path.join(iconsDir, dir)).forEach(file => {
          let name = path.basename(file, ".svg") + suffix
          values[name] = { name, fullPath: path.join(iconsDir, dir, file) }
        })
      })
      matchComponents({
        "hero": ({ name, fullPath }) => {
          let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
          let size = theme("spacing.6")
          if (name.endsWith("-mini")) {
            size = theme("spacing.5")
          } else if (name.endsWith("-micro")) {
            size = theme("spacing.4")
          }
          return {
            [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
            "-webkit-mask": `var(--hero-${name})`,
            "mask": `var(--hero-${name})`,
            "mask-repeat": "no-repeat",
            "background-color": "currentColor",
            "vertical-align": "middle",
            "display": "inline-block",
            "width": size,
            "height": size
          }
        }
      }, { values })
    })
  ]
}
