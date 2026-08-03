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

## Prompt 7

```text
OK of the possible next steps what we like the best is biulding an iOS app MVP that we can use to verify that the whole scheme will work end to end. Do we need to split that into phases or can we just reate an MVP in one go? Propose a plan for us to approve.
```

## Prompt 8

```text
that's a pretty long plan, let's record it as IOS_MVP_PLAN.md so that we can review it in detail.
```

## Prompt 9

```text
I'm usign glow to view this in another terminal but it seems that bullets aren't rendering correctly, perhaps my terminal doesn't support unicode. what parameter can I pass to glow to make it render in ASCII only
```

## Prompt 10

```text
the plan looks reasonable. the PR is merged but the local repo is on the branch still, you can pull main and do phase 1 of the plan. Can we easily migrate/link Lori's existing data into the new schema? Let's put that up as our next PR (a way for her to log in/link the existing data she has entered into her gmail account)
```

## Prompt 11

```text
Lori tried to link her account and it returned her to the schedule page but still had the banner saying she needs to link it. I tried doing the same in my account/brwoser profile and saw the same behaviour. Then I reloaded, and now I acn't seem to get back to my schedule. Inspect the firestore data and see if things have gone awry? This doesn't seem to be the desired otucome
```

## Prompt 12

```text
Fix what needs fixing and tell us what the next steps are after updating the PR
```
