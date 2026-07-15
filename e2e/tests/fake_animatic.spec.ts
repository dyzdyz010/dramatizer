import {test, expect} from "@playwright/test"
import {execFileSync} from "node:child_process"
import {mkdirSync, readFileSync, writeFileSync} from "node:fs"
import path from "node:path"

test("Fake novel-to-animatic production, recovery, routes, and media", async ({page, request, baseURL}) => {
  const root = path.resolve(import.meta.dirname, "../..")
  const artifactRoot = path.join(root, "output", "playwright")
  const origin = baseURL!
  mkdirSync(artifactRoot, {recursive: true})

  const waitForLiveView = async () => {
    await expect(page.locator(".phx-connected")).toBeAttached()
  }

  await page.goto("/")
  await waitForLiveView()
  await expect(page.getByRole("heading", {name: "短剧制作台"})).toBeVisible()
  await page.getByLabel("项目名称").fill(`浏览器验收-${Date.now()}`)
  await page.getByRole("button", {name: "创建项目"}).click()
  await expect(page).toHaveURL(/\/projects\/[^/]+\/source$/)

  const projectId = page.url().match(/\/projects\/([^/]+)\//)?.[1]
  expect(projectId).toBeTruthy()
  const stage = (name: string) => `/projects/${projectId}/${name}`
  const gotoStage = async (name: string) => {
    await page.goto(stage(name))
    await waitForLiveView()
  }

  await page.locator("input[type=file]").setInputFiles(path.join(root, "e2e", "fixtures", "novel.md"))
  await expect(page.locator("#source-upload-form progress")).toHaveAttribute("value", "100")
  await page.getByRole("button", {name: "解析并落盘"}).click()
  await expect(page.getByText("novel.md")).toBeVisible()
  await expect(page.locator("main[data-state=ready]")).toBeVisible()

  await gotoStage("analysis")
  await page.getByRole("button", {name: "启动全文分析"}).click()
  await expect(page.locator("main[data-stage=analysis][data-state=ready]")).toBeVisible()
  await expect(page.locator(".dag-node [data-state=ready]")).toHaveCount(6)

  await gotoStage("episodes")
  await page.getByRole("button", {name: "选择并创建 Narrative"}).click()
  await page.getByRole("button", {name: "确认并冻结 Revision"}).click()
  await expect(page.getByText("已冻结为不可变 Revision。")).toBeVisible()

  await gotoStage("visuals")
  await page.getByRole("button", {name: "创建 VisualDesign"}).click()
  await page.getByRole("button", {name: "确认并冻结 Revision"}).click()

  const referencePath = path.join(artifactRoot, "reference.png")
  execFileSync(
    path.join(root, "app", ".venv", "Scripts", "python.exe"),
    [
      "-c",
      "from PIL import Image; import sys; Image.new('RGB', (270, 480), (32, 58, 74)).save(sys.argv[1], format='PNG')",
      referencePath
    ]
  )
  await page.locator("input[type=file]").setInputFiles(referencePath)
  await expect(page.locator("#media-upload-form progress")).toHaveAttribute("value", "100")
  await page.getByRole("button", {name: "存入素材库"}).click()
  await expect(page.getByText("参考图已进入统一 AssetStore。")).toBeVisible()

  const referenceSelects = page.locator("#reference-set-form select")
  await expect(referenceSelects).toHaveCount(6)
  await expect(referenceSelects.first().locator("option")).toHaveCount(2)
  for (let index = 0; index < (await referenceSelects.count()); index++) {
    await referenceSelects.nth(index).selectOption({index: 1})
  }
  await page.getByRole("button", {name: "创建 ReferenceSet 草稿"}).click()
  await page.getByRole("button", {name: "确认并冻结 Revision"}).click()

  await gotoStage("shots")
  await page.getByRole("button", {name: "创建 ShotPlan 草稿"}).click()
  await page.getByRole("button", {name: "确认并冻结 Revision"}).click()
  await page.getByRole("button", {name: "编译冻结 GenerationSpec"}).click()
  await page.getByRole("button", {name: "生成候选并执行 QC"}).click()
  await expect(page.locator(".candidate-card")).toHaveCount(6, {timeout: 90_000})

  for (const shotId of ["S001", "S002", "S003"]) {
    const candidate = page.locator(`button[phx-value-slot-key="shot:${shotId}"]:not([disabled])`).first()
    await candidate.click()
    await expect(page.locator(`button[phx-value-slot-key="shot:${shotId}"][disabled]`)).toHaveCount(1)
  }

  await gotoStage("timeline")
  await page.getByRole("button", {name: "从已确认输入创建"}).click()
  const firstSubtitle = page.locator("input[id^=subtitle-text-]").first()
  await firstSubtitle.fill("这封信绝不该出现在这里。")
  await firstSubtitle.locator("xpath=ancestor::form").getByRole("button", {name: "保存"}).click()

  await page.getByRole("button", {name: "生成预览"}).click()
  await expect(page.locator('a[download="dramatizer-preview.mp4"]')).toBeVisible({timeout: 90_000})
  await page.getByRole("button", {name: "冻结并正式导出"}).click()
  const formalMp4 = page.locator('a[download="dramatizer-formal.mp4"]')
  const formalSrt = page.locator('a[download="dramatizer-formal.srt"]')
  await expect(formalMp4).toBeVisible({timeout: 120_000})
  await expect(formalSrt).toBeVisible()

  const mp4Href = await formalMp4.getAttribute("href")
  const srtHref = await formalSrt.getAttribute("href")
  expect(mp4Href).toBeTruthy()
  expect(srtHref).toBeTruthy()

  const mp4Response = await request.get(new URL(mp4Href!, origin).toString())
  const srtResponse = await request.get(new URL(srtHref!, origin).toString())
  expect(mp4Response.ok()).toBeTruthy()
  expect(mp4Response.headers()["content-type"]).toContain("video/mp4")
  expect(srtResponse.ok()).toBeTruthy()
  expect(await srtResponse.text()).toContain("这封信绝不该出现在这里。")

  const mp4Path = path.join(artifactRoot, "fake-formal.mp4")
  writeFileSync(mp4Path, await mp4Response.body())
  const probe = JSON.parse(
    execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", mp4Path], {
      encoding: "utf8"
    })
  )
  const video = probe.streams.find((stream: {codec_type: string}) => stream.codec_type === "video")
  const audio = probe.streams.find((stream: {codec_type: string}) => stream.codec_type === "audio")
  expect(video.codec_name).toBe("h264")
  expect(video.pix_fmt).toBe("yuv420p")
  expect([video.width, video.height]).toEqual([1080, 1920])
  expect(audio.codec_name).toBe("aac")
  expect(audio.channels).toBe(2)

  for (const route of ["source", "analysis", "episodes", "visuals", "shots", "timeline", "runs"]) {
    const response = await request.get(new URL(stage(route), origin).toString())
    expect(response.status(), route).toBe(200)
  }

  await gotoStage("runs")
  await page.getByRole("button", {name: "注入一次 Fake 失败"}).click()
  await expect(page.getByText("Fake 首次提交已按计划失败。")).toBeVisible()
  await page.getByRole("button", {name: "恢复并注入重复乱序回调"}).click()
  await expect(page.getByText("Fake 节点已恢复；重复/乱序回调已去重。")).toBeVisible()
  const costAfterRecovery = await page.locator(".cost-strip strong").textContent()
  await page.getByRole("button", {name: "恢复并注入重复乱序回调"}).click()
  await expect(page.locator(".cost-strip strong")).toHaveText(costAfterRecovery || "")

  await page.screenshot({path: path.join(artifactRoot, "fake-production-workspace.png"), fullPage: true})
  expect(readFileSync(mp4Path).byteLength).toBeGreaterThan(1_000)
})
