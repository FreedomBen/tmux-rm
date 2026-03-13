# Not Run Yet

- Right up a README.md file for this repo

- Let's add support for Cloudflare and Tailscale, so if an API key is present and the setting is enabled, we can update DNS and/or enable a tunnel.

- Let's add support for getting a TLS certificate from Let's Encrypt.  For this the user needs to enter the domain name or select to get an IP address certificate.

- Write a Makefile and include a build command, clean, and install.  The install should build and copy the server binary in place, and copy the systemd service file in place as well.

- Let's ensure we have full support for auth tokens, such that if the user wants to setup an auth token and disallow username/password auth, they can.  When auth token is enabled, the server should respond with a 401 or 403 to all requests that don't have the auth token included, even the home page.

# Already Run

- I'm thinking about adding a notification feature.  This is intended for long-running commands.  When a command finishes, pop up a notification informing the user.  Clicking on the notification should take you to the browser tab and put focus on the pane that triggered the notification.  What are your thoughts on this?  would it be complex and difficult to do in a portable way?

- Let's make sure the reset to default button in settings doesn't override the saved password info.

- Where did the quick action buttons go?  Let's also add one for Ctrl+d, Ctrl+c, 

- Let's add a control for creating a new window in a session.

- Would adding support to this server for MCP provide any value?  Can you think of any situations where an AI agent may want to use it?

- When split in the UI, Let's make the panes resizable by click and dragging on the divider.  This should also work on mobile.

- When in initial setup, populate the username with the host OS user name

- Let's go through the application and ensure that we are logging any meaningful action.

- In the UI, clicking on a pane should cause the tmux focus to be shifted to that pane.

- What are our distribution options for the web app?  can we compile to a static binary for linux?

- How can we make our test suite run faster?  Right now it's pretty slow

- /init for each thing

- Let's write up a comprehensive implementation plan.  Break into phases if necessary.  Write each phase to a separate file in implementation-docs directory with names like PHASE_01_DO_SOMETHING.md.  Don't plan implementation for the android app quite yet, but do the entire server.  Make sure all features from APPLICATION_DESIGN.md are planned, and make sure we implement the tech stack from TECH_STACK.md.  

- Let's add the design details for the android app to APPLICATION_DESIGN.md .  Start with everything you already know and can infer from the rest of the document, and then make a list of things we need to decide on.

- Let's define out tech stack.  Write decision to TECH_STACK.md.  Write out what we already know, and let's discuss the remaining options.  We do want to use tailwind css.  I bought a tailwind UI/tailwind Plus license and have files in ~/gitclone/tailwind-ui-tailwind-plus/tailwindplus that you can and should use as a starting point.  What else do we need to decide on for the tech stack?

- On startup, if the config file doesn't already exist, write the default config file to the file location

- Let's note that we want the ability for users to change settings and add quick actions through the UI.  We'll also need an API so that the mobile app can do this as well.

- I'd like to add the ability to create  buttons that will execute common commands to make it easier, especially on mobile.  For example, if the user frequently runs a command like "git add . && git commit -m . && git push" they could add that so a button tap sends that text (as though they typed it).  Since we don't currently have a database, it would be great if all configuration (including this) we're human editable, like a yaml or json file.  What are your thoughts on this?
