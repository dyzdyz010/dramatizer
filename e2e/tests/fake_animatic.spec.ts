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
  await expect(page.getByText("Fake 模拟模式")).toBeVisible()
  await expect(page.locator("aside[aria-label='制作阶段']")).toBeVisible()
  await expect(page.locator("main[data-workspace-canvas]")).toBeVisible()
  await expect(page.locator("aside[data-inspector]")).toBeVisible()
  await expect(page.locator("[data-next-action]")).toBeVisible()

  const projectId = page.url().match(/\/projects\/([^/]+)\//)?.[1]
  expect(projectId).toBeTruthy()
  const stage = (name: string) => `/projects/${projectId}/${name}`
  const gotoStage = async (name: string) => {
    await page.goto(stage(name))
    await waitForLiveView()
  }

  await gotoStage("runs")
  const modelOverride = page.locator("#model-override-form")
  await modelOverride.locator("select[name='model_override[task_type]']").selectOption("reference_image")
  await modelOverride.locator("input[name='model_override[candidate_count]']").fill("1")
  await modelOverride.getByRole("button", {name: "保存模型覆盖"}).click()
  await expect(page.getByText("项目模型覆盖已保存。")).toBeVisible()
  await gotoStage("source")

  await page.locator("input[type=file]").setInputFiles(path.join(root, "e2e", "fixtures", "novel.md"))
  await expect(page.locator("#source-upload-form progress")).toHaveAttribute("value", "100")
  await page.getByRole("button", {name: "解析并落盘"}).click()
  await expect(page).toHaveURL(new RegExp(`/projects/${projectId}/analysis$`), {timeout: 90_000})
  await expect(page.getByText("原著已解析，全文分析已加入队列。")).toBeVisible()
  await expect(page.locator("main[data-stage=analysis][data-state=ready]")).toBeVisible()
  await expect(page.locator(".dag-node [data-state=ready]")).toHaveCount(6)
  await expect(page.locator(".analysis-review").getByRole("heading", {name: "人物与关系"})).toBeVisible()

  await gotoStage("episodes")
  await page.getByRole("button", {name: "选择并创建 Narrative"}).click()
  await expect(page.getByText("Narrative 提案已加入队列。")).toBeVisible()
  await expect(page.getByRole("heading", {name: "分集概览"})).toBeVisible()
  await expect(page.getByRole("heading", {name: "Scene 与 Beat"})).toBeVisible()
  await page.getByRole("button", {name: "确认并冻结 Revision"}).click()
  await expect(page.getByText("Narrative 已冻结，VisualDesign 提案已加入队列。")).toBeVisible()

  await gotoStage("visuals")
  await expect(page.getByText("视觉 Variant", {exact: true}).first()).toBeVisible()
  await page.getByRole("button", {name: "确认并冻结 Revision"}).click()
  await page.getByRole("button", {name: "AI 生成参考候选"}).click()
  await expect(page.getByText("参考图候选已加入队列。")).toBeVisible()
  const requiredReferenceSlots = await page.locator("[data-reference-slot]").count()
  expect(requiredReferenceSlots).toBeGreaterThan(0)
  const referenceGroups = page.locator("[data-candidate-group^='reference:']")
  await expect(referenceGroups).toHaveCount(requiredReferenceSlots, {timeout: 120_000})
  const referenceGroupCount = await referenceGroups.count()
  expect(referenceGroupCount).toBe(requiredReferenceSlots)
  for (let index = 0; index < referenceGroupCount; index++) {
    await referenceGroups.nth(index).getByRole("button", {name: "选择为主图"}).first().click()
  }
  await expect(page.locator("[data-reference-slot] .matrix-readiness.is-ready")).toHaveCount(
    requiredReferenceSlots
  )
  await page.getByRole("button", {name: "从已选主图创建 ReferenceSet"}).click()
  await expect(page.getByText("ReferenceSet 草稿已由明确选择创建。")).toBeVisible()
  await page.locator(".reference-set-editor").getByRole("button", {name: "确认并冻结 Revision"}).click()
  await expect(page.getByText("ReferenceSet 已冻结，Directing 提案已加入队列。")).toBeVisible()

  await gotoStage("shots")
  await expect(page.getByText("连续性", {exact: true}).first()).toBeVisible()
  await page.getByRole("button", {name: "确认并冻结 Revision"}).click()
  await page.getByRole("button", {name: "编译冻结 GenerationSpec"}).click()
  await page.getByRole("button", {name: "生成候选并执行 QC"}).click()
  await expect(page.getByText("镜头候选已加入队列。")).toBeVisible()
  await expect(page.locator(".candidate-card")).toHaveCount(6, {timeout: 90_000})

  const shotGroups = page.locator("[data-candidate-group^='shot:']")
  await expect(shotGroups).toHaveCount(3)
  for (let index = 0; index < (await shotGroups.count()); index++) {
    await shotGroups.nth(index).getByRole("button", {name: "选择为主图"}).first().click()
  }

  await gotoStage("timeline")
  await page.getByRole("button", {name: "从已确认输入创建"}).click()
  const firstSubtitle = page.locator("input[id^=subtitle-text-]").first()
  await firstSubtitle.fill("这封信绝不该出现在这里。")
  await firstSubtitle.locator("xpath=ancestor::form").getByRole("button", {name: "保存"}).click()

  await page.getByRole("button", {name: "生成预览"}).click()
  await expect(page.getByText("预览渲染已加入队列。")).toBeVisible()
  await expect(page.locator('a[download="dramatizer-preview.mp4"]')).toBeVisible({timeout: 90_000})
  await page.getByRole("button", {name: "冻结并正式导出"}).click()
  await expect(page.getByText("正式渲染已加入队列。")).toBeVisible()
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
  await expect(page.getByText("Fake 故障探针已加入队列。")).toBeVisible()
  await expect(page.locator(".error-chip").filter({hasText: "Provider 拒绝了请求，可调整输入后重试"})).toBeVisible()
  const recoveryCost = page.locator(".cost-strip strong")
  const costBeforeRecovery = await recoveryCost.textContent()
  await page.getByRole("button", {name: "恢复并注入重复乱序回调"}).click()
  await expect(page.getByText("Fake 故障节点已重新排队。")).toBeVisible()
  await expect(page.locator("[data-stage='runs']")).toHaveAttribute("data-state", "ready")
  await expect(recoveryCost).not.toHaveText(costBeforeRecovery || "")
  const costAfterRecovery = await recoveryCost.textContent()
  expect(costAfterRecovery?.trim()).toBeTruthy()
  await page.getByRole("button", {name: "恢复并注入重复乱序回调"}).click()
  await expect(recoveryCost).toHaveText(costAfterRecovery || "")

  for (const forbidden of ["Narrative JSON", "VisualDesign JSON", "ShotPlan JSON", "结构化内容"]) {
    await expect(page.getByText(forbidden, {exact: false})).toHaveCount(0)
  }
  const textareas = page.locator("textarea")
  const textareaValues: string[] = []
  for (let index = 0; index < (await textareas.count()); index++) {
    textareaValues.push(await textareas.nth(index).inputValue())
  }
  const rawJsonEditors = textareaValues.filter(value => /^\s*[\[{]/.test(value))
  expect(rawJsonEditors).toHaveLength(0)

  await page.screenshot({path: path.join(artifactRoot, "fake-production-workspace.png"), fullPage: true})
  expect(readFileSync(mp4Path).byteLength).toBeGreaterThan(1_000)
})
