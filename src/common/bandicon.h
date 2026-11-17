/*
 * The band icon's shape: three thin arcs for the signal over the band's
 * number ("2.4", "5", "6"). Shared by the status bar add-on (src/bar), which
 * draws it in place of iOS's Wi-Fi icon, and the app (src/app), which shows
 * it on the welcome screen, so both are always the same.
 *
 * Needs UIKit and CoreText.
 */
#ifndef WT_BANDICON_H
#define WT_BANDICON_H
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

/* The letters' own outline (not the line's), relative to where the text starts
 * on its baseline (y up). */
static CGRect wtInk(NSString *text, UIFont *font)
{
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:@{ NSFontAttributeName: font }];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGRect r = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    CFRelease(line);
    if (CGRectIsNull(r) || r.size.width <= 0) {   /* fall back to the line's width */
        CGSize s = [text sizeWithAttributes:@{ NSFontAttributeName: font }];
        r = CGRectMake(0, 0, s.width, font.capHeight);
    }
    return r;
}

/* One arc of the fan: a ring segment 45 degrees either side of straight up. */
static UIBezierPath *wtArc(CGPoint c, CGFloat r0, CGFloat r1)
{
    UIBezierPath *p = [UIBezierPath bezierPathWithArcCenter:c radius:r1 startAngle:-3 * M_PI_4 endAngle:-M_PI_4 clockwise:YES];
    [p addArcWithCenter:c radius:r0 startAngle:-M_PI_4 endAngle:-3 * M_PI_4 clockwise:NO];
    [p closePath];
    return p;
}

/* The new icon's shape in box (points), drawn in black at the strength of
 * each part: the number solid, arcs solid up to the signal level and dimmed
 * above it. Proportions of the box, so it scales with the icon:
 *   number: digits 55% of the height, sitting on the bottom (no wider than
 *           92% of the box);
 *   arcs:   each 8.5% of the height thick, 5% apart, the outer one as wide
 *           as the box (its tips 0.2 pt in from the sides) and touching the
 *           top; cut off 7% of the height above the number, so they never
 *           touch it. */
static void wtDrawShape(CGRect box, NSString *text, int bars, CGFloat full, CGFloat dim)
{
    CGFloat w = box.size.width, h = box.size.height;
    UIFont *ref = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    CGFloat size = MIN(10 * h * 0.55 / ref.capHeight, 10 * w * 0.92 / wtInk(@"2.4", ref).size.width);
    UIFont *font = [UIFont systemFontOfSize:round(size * 4) / 4 weight:UIFontWeightBold];
    CGFloat base = CGRectGetMaxY(box) - MAX(0.15, h * 0.014);
    CGFloat textTop = base - font.capHeight;
    CGRect ink = wtInk(text, font);

    CGFloat t = h * 0.085, g = h * 0.05;
    CGFloat R = (w / 2 - 0.2) / sin(M_PI_4);
    CGPoint c = CGPointMake(CGRectGetMidX(box), CGRectGetMinY(box) + MAX(0.1, h * 0.01) + R);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(CGRectGetMinX(box) - 2, CGRectGetMinY(box) - 2, w + 4,
                                        textTop - h * 0.07 - CGRectGetMinY(box) + 2));
    for (int i = 0; i < 3; i++) {   /* inner arc first: it's the first bar */
        CGFloat outer = R - (2 - i) * (t + g);
        [[UIColor colorWithWhite:0 alpha:(i < bars ? full : full * dim)] setFill];
        [wtArc(c, outer - t, outer) fill];
    }
    CGContextRestoreGState(ctx);

    [text drawAtPoint:CGPointMake(CGRectGetMidX(box) - (ink.origin.x + ink.size.width / 2), base - font.ascender)
       withAttributes:@{ NSFontAttributeName: font,
                         NSForegroundColorAttributeName: [UIColor colorWithWhite:0 alpha:full] }];
}

#endif
