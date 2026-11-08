"""Interaction and transition regression checks for the corrected reference timeline."""
import asyncio
import json
from playwright.async_api import async_playwright


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--no-sandbox"])
        page = await browser.new_page(viewport={"width": 480, "height": 920})
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        await page.goto("http://127.0.0.1:8765/preview/?capture", wait_until="networkidle")
        motion = await page.evaluate("""() => ({
          finite:Array.from({length:3681},(_,i)=>state(1+i/20)).every(s=>
            Object.values(s).every(v=>typeof v!=='number'||Number.isFinite(v))),
          open12:state(12).flySize,open20:state(20).flySize,open25:state(25).flySize,
          midFlip:state(118).flip,back:state(150).back,
          close169:state(169).flip,close184:state(184).flySize,
          openingHandoff:Math.abs(state(26.999).flySize-state(27).flySize),
          pullBoundary:Math.abs(state(96.999).pull-state(97).pull),
          detailTabHidden:getComputedStyle(document.querySelector('.detail .tabbar')).display==='none',
          missingImages:[...document.images].filter(i=>!i.complete||!i.naturalWidth).length
        })""")
        assert motion["finite"] and motion["missingImages"] == 0, motion
        assert motion["open12"] < motion["open20"] < motion["open25"], motion
        assert motion["midFlip"] > 90 and motion["back"], motion
        assert motion["close169"] < -90 and motion["close184"] < 76, motion
        assert motion["openingHandoff"] < .01 and motion["pullBoundary"] < .001, motion
        assert motion["detailTabHidden"], motion
        await page.locator('.cell[data-i="13"]').first.click()
        await page.wait_for_function("frame>27", timeout=2500)
        await page.locator("#artwork").click()
        await page.wait_for_function("frame===55 && !playing", timeout=2500)
        await page.locator("#artwork").click()
        await page.wait_for_function("frame===97 && !playing", timeout=2500)
        await page.locator("#btnClose").click()
        await page.wait_for_function("frame===185 && !playing", timeout=2500)
        await page.mouse.move(210, 300)
        await page.mouse.wheel(0, 180)
        await page.wait_for_function("document.querySelector('#grid').scrollTop>0", timeout=2000)
        edges = await page.evaluate("""() => {
          const s=document.querySelector('#screen').getBoundingClientRect();
          return [...document.querySelectorAll('.home .edgefade')].map(e=>{
            const r=e.getBoundingClientRect();return [r.top-s.top,r.bottom-s.top];
          });
        }""")
        assert edges[0][0] == 0 and edges[1][1] == 852, edges
        assert not errors, errors
        print(json.dumps({"motion": motion, "edges": edges, "errors": errors,
                          "interactions": "open, pull, retract, close, scroll passed"}, indent=2))
        await browser.close()


asyncio.run(main())
