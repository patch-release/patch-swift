import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://docs.patchrelease.com',
  integrations: [
    starlight({
      title: 'Patch Docs',
      description:
        'Over-the-air code updates for native Swift iOS apps. Compile changed Swift to WebAssembly and ship it without App Store review.',
      logo: { src: './src/assets/patch-icon.png', replacesTitle: false },
      social: {
        github: 'https://github.com/patch-release/patch-swift',
      },
      editLink: {
        baseUrl: 'https://github.com/patch-release/patch-swift/edit/main/docs/',
      },
      customCss: ['./src/styles/patch.css'],
      components: {
        // house header keeps the marketing nav reachable from docs
      },
      sidebar: [
        {
          label: 'Start here',
          items: [
            { slug: '' },
            { slug: 'quickstart' },
            { slug: 'how-it-works' },
            { slug: 'ai-setup' },
          ],
        },
        {
          label: 'What Patch can change',
          items: [
            { slug: 'coverage' },
            { slug: 'fingerprint' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { slug: 'cli' },
            { slug: 'sdk' },
          ],
        },
        {
          label: 'Shipping',
          items: [
            { slug: 'channels' },
            { slug: 'rollouts' },
            { slug: 'targeting' },
            { slug: 'force-updates' },
            { slug: 'cicd' },
          ],
        },
        {
          label: 'Open source & self-hosting',
          items: [
            { slug: 'open-source' },
            { slug: 'self-hosting' },
            { slug: 'apple-compliance' },
          ],
        },
        {
          label: 'Account',
          items: [
            { slug: 'team' },
            { slug: 'billing' },
            { slug: 'usage' },
            { slug: 'audit' },
            { slug: 'webhooks' },
          ],
        },
        {
          label: 'Help',
          items: [{ slug: 'troubleshooting' }],
        },
      ],
    }),
  ],
});
