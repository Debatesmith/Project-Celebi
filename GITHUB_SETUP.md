# Publishing Project Celebi on GitHub — First-Time Setup

Recommended repository name:

`Project-Celebi`

Recommended repository description:

`Carry a Pokémon Red/Blue/Yellow Gen1Recomp save into Gold as a veteran-trainer expansion, with continuity-aware progression and Johto scaling.`

Recommended topics:

`gen1recomp`, `pokemon`, `pokemon-gold`, `lua`, `love2d`, `modding`, `save-transfer`, `fan-mod`

## Easiest workflow on Windows: GitHub Desktop

1. Create a free GitHub account if you do not already have one.
2. Install **GitHub Desktop** and sign in.
3. In GitHub Desktop, choose **File → New repository**.
4. Name it `Project-Celebi`.
5. Choose where you want the repository stored locally.
6. Leave the license set to **None** for now unless you have deliberately chosen an open-source license.
7. Create the repository.
8. Copy the contents of this `ProjectCelebi-GitHub-Ready` folder into the new repository folder.
9. GitHub Desktop will show the added files under **Changes**.
10. Enter a commit summary such as `Initial Project Celebi public beta`.
11. Click **Commit to main**.
12. Click **Publish repository**.
13. Uncheck **Keep this code private** so the community can see it.
14. Publish.

## Create the downloadable beta

Do not make Discord users download the automatic GitHub "Source code" archive as the mod package.

Instead, create a proper GitHub Release and attach the tested mod ZIP:

`ProjectCelebi-v0.1.30.zip`

On the GitHub repository page:

1. Open **Releases**.
2. Choose **Draft a new release**.
3. Create tag: `v0.1.30-beta`
4. Release title: `Project Celebi v0.1.30 — Public Beta`
5. Check **Set as a pre-release** / **This is a pre-release**.
6. Paste the contents of `RELEASE_NOTES_v0.1.30.md` into the description.
7. Drag `ProjectCelebi-v0.1.30.zip` into the release assets area.
8. Publish the release.

That Release page is the link to share on Discord.

## Suggested About text

**Description**

`Continue a Gen 1 Gen1Recomp save into Pokémon Gold as a veteran trainer.`

**Website**

Leave blank unless you later create a project page.

**Topics**

`gen1recomp pokemon pokemon-gold lua love2d modding save-transfer fan-mod`

## Future updates

For the next mod version:

1. Replace/update files inside `project_celebi/`.
2. Update `README.md` if behavior changed.
3. Add the new version to `CHANGELOG.md`.
4. Commit the changes in GitHub Desktop.
5. Click **Push origin**.
6. Create a new GitHub Release with the new tested ZIP attached.

Keep old Releases available so players can report exactly which build they were using.
