/*
 * Copyright (C) 2018 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import indicatorRegion from '../../src/rce/indicatorRegion'

describe('IndicatorRegion module', () => {
  let editor, iframe, target, offsetFake

  beforeEach(() => {
    iframe = {}
    editor = {
      getContainer() {
        return {querySelector: () => iframe}
      },
    }
    offsetFake = jest.fn(() => {
      return {
        top: 1,
        left: 2,
        width: 3,
        height: 4,
      }
    })
    target = {
      getBoundingClientRect() {
        return {
          top: 5,
          left: 6,
          right: 16,
          bottom: 25,
        }
      },
    }
  })

  describe('indicatorRegion', () => {
    let region

    beforeEach(() => {
      region = indicatorRegion(editor, target, offsetFake)
    })

    it('includes the width and height of the target', () => {
      expect(region.height).toEqual(20)
      expect(region.width).toEqual(10)
    })

    it('gets offset of iframe', () => {
      expect(offsetFake).toHaveBeenCalledWith(iframe)
    })

    it('includes sum of the left offsets of the target and iframe', () => {
      expect(region.left).toEqual(8)
    })

    it('includes sum of the top offsets minus the iframe scroll', () => {
      expect(region.top).toEqual(6)
    })
  })
})
