/*
 * Copyright (C) 2023 - present Instructure, Inc.
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

import {useCallback, useEffect, useState} from 'react'
import type {
  GradebookStudentDetails,
  GradebookUserSubmissionDetails,
  SubmissionGradeChange,
} from '../../types'
import {fetchStudentSubmission} from '../../queries/Queries'
import {useQuery} from '@tanstack/react-query'

type Response = {
  currentStudent?: GradebookStudentDetails
  studentSubmissions?: GradebookUserSubmissionDetails[]
  loadingStudent: boolean
  updateSubmissionDetails: (submission: SubmissionGradeChange) => void
}

export const useCurrentStudentInfo = (courseId: string, userId?: string | null): Response => {
  const [currentStudent, setCurrentStudent] = useState<GradebookStudentDetails>()
  const [studentSubmissions, setStudentSubmissions] = useState<GradebookUserSubmissionDetails[]>()

  const queryKey: [string, string, string] = [
    'individual-gradebook-student',
    courseId,
    userId ?? '',
  ]

  const {data, error, isLoading} = useQuery({
    queryKey,
    queryFn: fetchStudentSubmission,
    enabled: !!userId,
  })

  useEffect(() => {
    if (!userId) {
      setCurrentStudent(undefined)
      setStudentSubmissions(undefined)
    }
  }, [userId])

  useEffect(() => {
    if (error) {
      // TODO: handle error
    }

    if (data?.course) {
      setCurrentStudent(data.course.usersConnection.nodes[0])
      setStudentSubmissions(data.course.submissionsConnection.nodes)
    }
  }, [data, error])

  const updateSubmissionDetails = useCallback(
    (newSubmission: SubmissionGradeChange) => {
      setStudentSubmissions(submissions => {
        if (!submissions) return
        const index = submissions.findIndex(s => s.id === newSubmission.id)
        if (index > -1) {
          submissions[index] = {...submissions[index], ...newSubmission}
        }
        return [...submissions]
      })
    },
    [setStudentSubmissions],
  )

  return {
    currentStudent,
    studentSubmissions,
    loadingStudent: isLoading,
    updateSubmissionDetails,
  }
}
