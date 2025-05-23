/*
 * Copyright (C) 2014 - present Instructure, Inc.
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

import React from 'react'
import Lti2Permissions from '../Lti2Permissions'
import {render, screen} from '@testing-library/react'

describe('Lti2Permissions', () => {
  test('renders', () => {
    const tool = {
      app_id: 3,
      app_type: 'Lti::ToolProxy',
      description: null,
      enabled: false,
      installed_locally: true,
      name: 'SomeTool',
    }
    render(
      <Lti2Permissions tool={tool} handleCancelLti2={jest.fn()} handleActivateLti2={jest.fn()} />,
    )

    expect(screen.getByText(/Would you like to enable this app\?/i)).toBeInTheDocument()
  })
})
