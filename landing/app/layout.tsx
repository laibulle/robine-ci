import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geist = Geist({ variable: "--font-geist", subsets: ["latin"] });
const mono = Geist_Mono({ variable: "--font-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  metadataBase: new URL("https://robine-ci.com"),
  title: "Robine CI — Your code. Your rules. Your infrastructure.",
  description: "Fast, self-hosted, open-source CI/CD. Keep control of your code, secrets, and infrastructure.",
  openGraph: {
    title: "Robine CI",
    description: "Your code. Your rules. Your infrastructure.",
    locale: "en_US",
    type: "website",
  },
  twitter: { card: "summary" },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body className={`${geist.variable} ${mono.variable}`}>{children}</body></html>;
}
