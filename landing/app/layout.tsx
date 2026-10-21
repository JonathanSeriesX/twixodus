import "./globals.css";

import type { Metadata, Viewport } from "next";
import { Montserrat } from "next/font/google";
import { ThemeProvider } from "next-themes";

import { LiquidPointer } from "./liquid-pointer";

const bodyFont = Montserrat({
  subsets: ["latin"],
  variable: "--font-body",
  display: "swap",
});

const url = "https://twixodus.evgenii.org";
const description =
  "The ultimate tool to seamlessly import your Twitter archive into the Day One journaling app.";

export const metadata: Metadata = {
  metadataBase: new URL(url),
  title: "Twixodus",
  description,
  robots: { index: true, follow: true },
  /* Tab icons are the real Icon Composer render (squircle and material baked
     in, since nothing masks a favicon). apple-touch-icon is deliberately the
     flat full-bleed square instead — iOS applies its own mask and gloss, so a
     pre-rounded, pre-shadowed image would get double-treated. favicon.ico is
     absent here on purpose: it has to answer /favicon.ico at the origin root,
     so it sits in public/ rather than R2. */
  icons: {
    icon: [
      { url: "https://r2.evgenii.org/twixodus/icon-32.png", sizes: "32x32", type: "image/png" },
      { url: "https://r2.evgenii.org/twixodus/icon-192.png", sizes: "192x192", type: "image/png" },
    ],
    apple: { url: "https://r2.evgenii.org/twixodus/apple-touch-icon.png", sizes: "180x180" },
  },
  openGraph: {
    title: "Twixodus",
    description,
    siteName: "twixodus",
    locale: "en_GB",
    type: "website",
    url,
    images: [
      { url: "https://r2.evgenii.org/twixodus/twatter.jpg", width: 637, height: 637, alt: "Twixodus" },
    ],
  },
  twitter: {
    card: "summary",
    creator: "@JonathanSeriesX",
    images: ["https://r2.evgenii.org/twixodus/twatter.jpg"],
  },
};

export const viewport: Viewport = {
  /** browser chrome colour — keep in step with --paper in globals.css */
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#f7f4ef" },
    { media: "(prefers-color-scheme: dark)", color: "#131110" },
  ],
};

const beaconToken = process.env.NEXT_PUBLIC_CF_BEACON_TOKEN;

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    // suppressHydrationWarning: theme class is set pre-hydration by next-themes
    <html lang="en" className={bodyFont.variable} suppressHydrationWarning>
      <body className="font-sans antialiased">
        <ThemeProvider
          attribute="class"
          themes={["light", "dark", "black"]}
          enableColorScheme={false}
        >
          <div className="grain" aria-hidden />
          <LiquidPointer />
          {children}
        </ThemeProvider>
        {/* Cloudflare Web Analytics. Netlify sets the token for production
            only, so deploy previews, forks and local builds stay untracked. */}
        {beaconToken && (
          <script
            defer
            src="https://static.cloudflareinsights.com/beacon.min.js"
            data-cf-beacon={JSON.stringify({ token: beaconToken })}
          />
        )}
      </body>
    </html>
  );
}
