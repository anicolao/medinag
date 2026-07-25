# Prompts

## Prompt 1

```text
Read allthe markdown in this repository to get oriented. Tehn read ../food/E2E_GUIDE, noting especially its zero pixel tolerance and demands for no waiting -only event driven waits- and time requirements for end to end tests. Then craft an almost identical document adapted for this project, capable of getting us user story walkthroughs with screenshots for all fo the admin web dashboard, the iOS app, and the WatchOS app. Put up the new E2E_GUIDE as a new PR for us to review. Before you start, make sure you're on main and have pulled hte latest from github.
```

## Prompt 2

```text
ok we are authenticated now
```

## Prompt 3

```text
OK that looked good, and we put it on main. Pull main again, make a new branch, and scaffold the admin dashboard webUI. Refer to food again to see how to write a workflow that will publish the PR's version of the webUI, write the appropriate end to end test, and put up a PR. For this initial scaffold, a welcome page that does nothing else is fine, just so that we can see a page serving on github pages. (You may need to use gh to enable gh pages)
```

## Prompt 4

```text
This looks good and we merged it to main. Swtich to main, pull, and use package.json to install firebase tools, initialize the firebase project, and implement the admin dashboard scheduling features. Put up a PR with that work.
```

## Prompt 5

```text
you were meant to use firebase tools to make a new medinag project, get its configuratina nd store tehm in gh secrets and use them as VITE_ variables for the gh pages build so that we could in fact test against production,. Let's fix that and update the PR so that the PR preview link is usable.
```

## Prompt 6

```text
This is looking good. Write PROMPTS.md to record all the prompts you have been given verbatim. Write NEXT_TIME.md to record what we've done so far and possible next steps or questions to resolve. Then we'll stop for today.
```
