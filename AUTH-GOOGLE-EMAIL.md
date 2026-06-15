# mbife - Google et verification email

## Service gratuit recommande

- Supabase Auth pour les emails de confirmation et les sessions.
- Google Cloud OAuth pour le bouton "Continuer avec Google".

Ces deux options permettent de commencer gratuitement. Pour une production plus large, tu pourras plus tard ajouter un SMTP gratuit/peu couteux, mais Supabase suffit pour les tests et les premiers utilisateurs.

## 1. Supabase Auth

Dans Supabase > Authentication > URL Configuration :

- Site URL : l'URL Vercel de mbife, par exemple `https://ton-site.vercel.app`
- Redirect URLs :
  - `https://ton-site.vercel.app`

Dans Authentication > Providers > Email :

- Activer email/password.
- Activer "Confirm email" pour forcer la verification email.

## 2. Google OAuth

Dans Google Cloud Console :

1. Creer ou ouvrir un projet.
2. APIs & Services > OAuth consent screen : configurer l'app.
3. Credentials > Create credentials > OAuth client ID.
4. Type : Web application.
5. Authorized redirect URI :
   - `https://mmsrozfrrzyyxwpebnxb.supabase.co/auth/v1/callback`

Ensuite, dans Supabase > Authentication > Providers > Google :

- Activer Google.
- Coller le Client ID Google.
- Coller le Client Secret Google.

## 3. Deploiement

Redeployer sur Vercel avec :

- `index.html`
- `sw.js`
- `manifest.json`
- `icon-192.png`
- `icon-512.png`
- `vercel.json`

Le zip pret a deployer est : `mbife-vercel-auth-google-20260604.zip`.
