// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import astroExpressiveCode from 'astro-expressive-code';

// https://astro.build/config
export default defineConfig({
    integrations: [
        astroExpressiveCode({
            themes: ['aurora-x'],
        }),
        starlight({
            title: 'Replecs',
            social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/PepeElToro41/replecs' }],
            sidebar: [
                {
                    label: 'Get Started',
                    autogenerate: { directory: 'started' },
                },
                {
                    label: 'Guides',
                    autogenerate: { directory: 'guides' },
                },
                {
                    label: 'API Reference',
                    autogenerate: { directory: 'reference' },
                },
            ],
            customCss: [
                // Path to your Tailwind base styles:
                './src/styles/theme.css',
                './src/styles/custom.css',
            ],
        }),
	],
});